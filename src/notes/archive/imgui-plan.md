# imgui-plan.md — finishing the imgui port

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
> 12. Don't read a variable in the same literal that overwrites it.
> 13. `extern struct` only at real FFI seams.
>
> Touching a function means bringing the whole function up to
> spec, not just the change.

---

## Where we are

Turn 264.  Phases A and B of the v2 parity arc shipped (9 steps,
turns 190-201).  The arc was paused for ~60 turns of architectural
detours (api-flatten, zmath adoption, codeberg pages, cheatsheet)
and is resuming now.

This document supersedes `imgui-parity-plan.md` (v2), which is
archived at `src/notes/archive/imgui-parity-plan-v2.md`.  v2's
function-level audit (§C1-C42), gap classification (§G), and
helper-type coverage (§E) remain factually correct and are the
authoritative reference for "what does imgui have that we don't
have yet."  Read v2 when you need that audit detail; read THIS
file for direction.

## What we're building

**Full imgui feature parity, done better.**  Every imgui.h
capability that translates to wasm gets a zimr equivalent.  Where
imgui's API shape is a C-language compromise (flat enums mixing
device categories, parallel-bool exclusive flag groups, text-format
settings persistence), zimr ships the cleaner Zig form.  We're not
1:1 on the API shape; we're 1:1 on capability and *better* on data
modeling.

The directive: "everything ocornut has, plus more."  When in doubt,
port — ocornut kept it for a reason.  If a feature later turns out
useless, we drop it then.  Today's lens is "if it's there, it's
there for a reason."

### Ambition markers — where we go further than imgui

These aren't separate features; they're how we ship parity.

- **`.zon` + localStorage persistence.**  imgui has text-INI that
  requires app code to wire up disk I/O.  zimr ships persistence
  that round-trips through localStorage automatically: drag a
  window, refresh the page, the window stayed.  Hooks into the
  TypeScript runtime in `src/web/zimr.ts`; opt-in per `UiContext`.

- **Mutually-exclusive flag groups become enums.**  Caller
  physically can't pick two; precedence is the value, not a hidden
  internal rule.  Continues the existing zimr pattern
  (`TableColumnSizing`, `ColorPickerLayout`).

- **`ImGuiKey` correctly typed.**  All 147 imgui Key values are
  covered, but mouse buttons live on `MouseButton`, gamepad buttons
  on gamepad inputs, modifier-only chord constituents on `KeyChord`
  modifier bools.  Same coverage, no category mixing.

- **Long-press → right-click on touch.**  imgui assumes right-click
  context menus exist.  On phones, they don't.  zimr maps long-press
  at the input layer so context menus work without per-demo gesture
  hacks.

- **Capstone updated incrementally.**  Each phase boundary adds one
  tab to `ui_full_showcase.zig`.  No giant final-turn assembly cliff.

- **`Value(label, v: anytype)`** — comptime-dispatches on the
  value's type (int, float, bool, enum, struct field).  imgui has
  a dozen `Value*` overloads; we have one.

- **Color conversion as methods on `Color`** — `Color.toHSV()`,
  `Color.fromHSV()` instead of free `colorConvertRGBtoHSV(...)`.
  Better discoverability via `.` autocomplete.

---

## Plan shape

| Phase | Steps | Theme | Anchor demo |
|---|---|---|---|
| 1 | 7 | Tier-1 features (+ child-window scroll, gap from 274; phone keyboard, gap from 282) | `ui_log_viewer` (extended), `ui_multiselect_finder`, `ui_panes` |
| 2 | 2 | Dev tools (pulled forward from v2's G1) | Metrics + DebugLog panels in `imgui_demo` |
| 3 | 6 | Flag-extension waves | one `ui_<group>_flags_tour.zig` per step |
| 4 | 6 | Tier-3 cleanup + Zig 0.16 modernization sweeps (turns 278-279) | extensions of `imgui_demo` + `ui_keys_themes_tour` |
| 5 | 3 | Persistence + niche-but-real | `ui_persistence` (HN demo), logging, DrawListSplitter |
| 6 | 1 | Capstone close + arc archive | final `ui_full_showcase` polish |
| **Total** | **25** | | |

Steps are planning units, not turn budgets.  A step might span 2
turns or fit in half a turn; the per-turn changelog records the
boundaries.  Step ordering reflects dependency + risk + impact;
deviations are fine as we go.

---

## Phase 1 — Tier-1 features (6 steps)

The features that block real apps (per v2's §G Tier-1 list, minus
A+B shipments).  Bulk of "visible new capability."

### Step 1.1 — Text helpers + `Value()` — ✅ DONE turns 266-277

Shipped: `separatorText`, `invisibleButton`, `textLink`,
`textLinkOpenURL`, `value` (one comptime fn replacing imgui's
12-overload set), plus gap-fill `setItemTooltip`.  Three new
Style slots: `text_link`, `text_link_hovered`, `text_link_underline`.
Demo: `examples/ui_log_viewer.zig` with severity-colored output
and clickable `[?]` links on error rows.  Surfaced + closed three
latent bugs along the way (blank-render at 80 lines, child-window
scrolling gap → Step 1.6, font baseline missing ascent → fixed
in turn 277).

### Step 1.2 — TextFilter — ✅ DONE turn 281

Shipped: `ui.TextFilter` type matching imgui's `ImGuiTextFilter`
1:1.  Methods `build()`, `passFilter(text)`, `isActive()`,
`clear()`, `draw(ui, label, hint)`.  Syntax: `include1,include2,-exclude1`
with case-insensitive ASCII matching and imgui-exact order-
matters semantics.  8 unit tests covering empty/include/exclude/
union/order/whitespace/empty-segments/clear.  Demo: log_viewer
gets a filter input above the log; Status section surfaces
`shown` count and "(filter active)" tag when the filter is doing
something.

### Step 1.3 — MultiSelect + SelectionBasicStorage — ✅ DONE turn 305

Shipped across turns 303-305 after rubberducking 6 design decisions:

- Turn 303: types (`MultiSelectFlags`, `SelectionRequest`,
  `MultiSelectIO`, `MultiSelectState`, `MultiSelectScope`,
  `SelectionBasicStorage`).  Scaffolded demo.  12 storage tests.
- Turn 304: real Begin/End + Header/Footer hooks for selectable.
  Click→request truth table from tutorial § 9 implemented.  10
  integration tests covering plain/Ctrl/Shift click + Escape +
  ClearOnClickVoid + no_auto_clear_on_reselect + no_range_select.
- Turn 305: phone tap-mode segmented control (Replace / Toggle /
  Range) synthesizing modifiers via the input snapshot.

`Ui.beginMultiSelect(flags, sel_size, items_count) *const MultiSelectIO`,
`Ui.endMultiSelect() *const MultiSelectIO`,
`Ui.setNextItemSelectionUserData(u64)`.  SelectionBasicStorage
backed by `std.AutoHashMapUnmanaged(u64, void)`.

17 `MultiSelectFlags` translated per the flag-decision rule (4
exclusive enums + 13 independent bools); 6 wired effective in MVP
(`selection`, `clear_on_escape`, `no_select_all`, `no_range_select`,
`no_auto_clear_on_reselect`, `clear_on_click_void`).  The other 11
exist with `// TODO Step 1.x` annotations citing imgui line refs.

Decisions logged:
- `?u64` for selection user-data (idiomatic Zig optional, not
  imgui's `-1` sentinel).
- Skip `AdapterIndexToStorageId` callback — indexes ARE IDs.
  Adapter filed for future reorderable-list demo.
- Per-scope state lives in `AutoHashMapUnmanaged(Id,
  MultiSelectState)` on `UiContext`.
- Single active-scope slot, no nesting (filed for future).
- Selectable signature unchanged; MS hooks additive.

Demo: `examples/ui_multiselect_finder.zig` — Finder-style 50-item
list.  Phone tap-mode toggle for Replace/Toggle/Range maps to
plain/Ctrl/Shift click respectively.  Tutorial:
`src/notes/multiselect-tutorial.md`.

Known limitations (filed):
- Ctrl-A inert until `InputSnapshot` gains per-letter key edges.
  Phone has no Ctrl-A; desktop users can use "Select All" button.
- Nestable scopes (single slot for now).
- Index→ID adapter for reorderable lists.
- Keyboard nav range-select preview (zimr has minimal kb-nav today).
- Box-select drag-rectangle (whole input subsystem).
- Right-click handling (no right-click on phone; low desktop pri).

### Step 1.4 — Splitter + window-size-constraints + setWindow* — ✅ DONE turn 308

Shipped across turns 306-308 after rubberducking 3 design
decisions:

- Turn 306: `Splitter` API + 2-pane scaffold demo (left tree +
  right editor with vertical splitter).  6 splitter tests.
- Turn 307: bottom output pane via horizontal splitter +
  `setNextWindowSizeConstraints` + `setWindowPos/Size/Focus`
  named variants.  9 more tests (size-constraints +
  setWindow*).
- Turn 308 (this): plan promotion.

API delivered:

```zig
pub fn splitter(self, str_id, *split_pos, axis: SplitterAxis, opts: SplitterOpts) bool;
pub fn setNextWindowSizeConstraints(self, min: ?Vector2, max: ?Vector2) void;
pub fn setWindowPos(self, name: []const u8, pos: Vector2) void;
pub fn setWindowSize(self, name: []const u8, size: Vector2) void;
pub fn setWindowFocus(self, name: []const u8) void;
```

`SplitterOpts` exposes both `bar_width` (visible) and
`hit_extend` (invisible grab pad) — touch ergonomics
decoupled from visual.  Default 4px bar + 16px extend each
side = 36px hit zone.

Decisions logged:
- Splitter: low-level only (no block-style wrapper) —
  compose with `beginChild` + `sameLine`.
- Demo: L-shape (left full-height tree + right top/bottom
  split) — classic IDE, exercises both axes.
- `setWindow*`: Always-semantics only, no Cond enum.

Demo: `examples/ui_panes.zig` — three-pane workspace with two
splitters at right angles.  Phone-readable (font 16, 380 wide
default).

Known limitations (filed):
- `setWindowCollapsed`: zimr lacks collapsed-window
  infrastructure entirely.
- `setNextWindowSizeConstraints` custom-callback variant
  (non-rectangular constraints).
- Cond enum (Always/Once/FirstUseEver/Appearing) for
  `setWindow*` family — MVP is Always-only.

### Step 1.5 — TreeNodeEx flags + tree polish

`TreeNodeOpts` covering the 26 `ImGuiTreeNodeFlags`.  Exclusive
groups become enums inline (`TreeOpenTrigger`, `TreeNodeSpan` likely
candidates).
Plus `setNextItemOpen`, `isItemToggledOpen`, `treeNodeGetOpen`,
`getTreeNodeToLabelSpacing`.

**Demo:** extend `ui_panes.zig`'s file-tree pane with framed nodes
+ leaf icons + programmatic-expand button.

### Step 1.6 — Proper child-window scrolling (gap discovered turn 274)

zimr's current `beginChild` is a clipped layout region — same
ChildState struct, same cursor redirect, but **no per-child scroll
state**.  `setScrollHereY` / `setScrollY` etc. inside a `beginChild`
operate on the OUTER window's scroll, which is wrong.  Discovered
when log_viewer's auto-scroll-to-bottom didn't fire (turn 274
phone test); confirmed by reading `ChildState` (`src/ui.zig:1528`)
— no `scroll_y` / `scroll_max_y` fields, no scrollbar rendering,
no mouse-wheel routing.

Imgui's `BeginChild` is a fully nested window with its own scroll
state, scrollbar, wheel-to-scroll, swipe-to-scroll-on-touch.  We
need the same.  Scope:

- `ChildState` gains `scroll_y`, `scroll_max_y`, and a stable
  identifier (probably the child's hashed string_id) so scroll
  state persists across frames.
- Scrollbar rendering when child content overflows.  Same visual
  style as the outer window's scrollbar (existing `style.scrollbar_*`
  slots cover it).
- Mouse wheel routes to the hovered child when one exists,
  falling back to the outer window otherwise.
- Touch swipe handling — drag-to-scroll inside a child rect.
  Critical for phone UX.
- `setScrollY` / `setScrollHereY` / `getScrollY` / `getScrollMaxY`
  all become child-aware: they read/write whichever scroll state
  is "current" (top of child_stack if non-empty, else outer
  window).

Workaround in `log_viewer` (landed turn 275): scroll the OUTER
window instead of using `beginChild`.  Works but loses the
"fixed-controls, scrollable log middle" UX pattern.  Restore the
intended structure when 1.6 ships.

**Demo:** extend `ui_panes.zig` (built in step 1.4) so each of the
three panes scrolls independently when its content overflows.
Phone-test: drag inside each pane should scroll that pane only,
not the outer window or sibling panes.

### Step 1.7 — Phone keyboard plumbing — ✅ DONE turns 282/283

Discovered turn 282 phone test: `inputText` widgets (introduced
to phone-visible code by the TextFilter demo in 1.2) don't pop
the soft keyboard.  Browsers refuse to show the on-screen
keyboard unless a real focusable DOM element has focus — a
canvas can never trigger it.  Pulled this in front of 1.3 per
Simon's "yak shaving until it is perfect" call.

Solution lands as a hidden-`<input>` overlapping the canvas,
managed by a new `extern fn js_request_soft_keyboard(active,
x, y, w, h)` called from `inputTextImpl` on focus/defocus
transitions.  The Zig side remains unchanged in spirit: chars
flow through the existing `chars_typed` queue regardless of
source (physical keyboard OR hidden input's `input` events).
"imgui all in userstate" architecturally intact — TS just
forwards events from one more DOM element.

Lives in:
- `src/web.zig` — `js_request_soft_keyboard` extern + `request_soft_keyboard`
  wrapper.
- `src/ui.zig` — `requestSoftKeyboard` helper + three call sites in
  `inputTextImpl` (click-focus, setKeyboardFocusHere, click-out / Esc / Enter
  defocus).
- `src/web/zimr.ts` — `js_request_soft_keyboard` handler + lazy hidden
  `<input>` creation + `input`/`keydown`/`keyup` listeners forwarding to
  the existing `input_push_char` and `input_push_key_down`/`up` queues.
- `RuntimeState.softKeyboardInput` — the cached element handle.

Backspace / Enter / arrow keys are forwarded as raylib key codes
through the existing keydown/keyup queue path, so all of ui.zig's
existing edit logic works without modification.

Bonus property: the hidden input also catches **paste events**
(via its `input` event firing on paste).  Paste support on
mobile is a free win.

**Turn 283 follow-up — keyboard-occluded widget visibility:**

Turn 282 phone test surfaced the next gap: the keyboard pops, but
it covers the bottom half of the screen, including the widget the
user just tapped.  Browsers shrink the VISUAL viewport (what's
visible) without changing the LAYOUT viewport (what CSS thinks
the page is sized at), so a widget at y=1300 in a 1400px canvas
ends up squarely under the keyboard.

Fix lives in `src/web/zimr.ts:attachInputHandlers`:

- Listen to `window.visualViewport.resize` + `scroll`.
- When `(window.innerHeight - visualViewport.height) > 100px`,
  shrink `canvas.style.height` to `visualViewport.height`.
- zimr's existing ResizeObserver fires on the style change →
  backing-store dims update → wasm sees a smaller window → widget
  layout naturally fits.
- On keyboard-down (visual viewport returns to ≈ layout viewport),
  restore the original canvas CSS height.

Also set `enterKeyHint = "done"` on the hidden input so the
mobile keyboard's submit button reads "Done" rather than the
default "Go", matching the no-form-submission semantics.

Both changes are TS-only; no Zig code touched.

**Demo:** the existing log_viewer's TextFilter input.  Tap it on
phone → soft keyboard pops up.

**Turn 285-286 follow-ups — scroll widget into view + restore:**

Turn 285: even with the canvas shrunk to fit the visual viewport,
a widget can still be hidden if the parent window's scroll has
pushed it below the visible area.  Added `scrollFocusedWidgetIntoView`
in `src/ui.zig` — on text-widget focus, scroll the parent window
so the widget lands at 25% from the top of the canvas.

Turn 286: completed the symmetry.  Save the window scroll on
focus, restore on defocus.  Without restore, mobile users got
scrolled UP on focus and never scrolled back DOWN — top of the
content became unreachable.

Storage: two new fields on `InputTextState` (saved_window_scroll_y
+ saved_window_id).  Restore looks up the window by id in
`ctx.windows` (robust against current_window drift between focus
and defocus paths).  Sentinel `-1` means "no save" (cleared after
restore).

Wired at both inputTextImpl defocus paths (click-outside,
Enter/Esc).

**Open followups inside Step 1.7 (deferred, NOT blocking):**

These are KNOWN-HARD problems in the imgui-on-mobile-emscripten
ecosystem.  Researched in turn 291 by reading prior art:

- imgui issue #5133 (March 2022): same bug Simon reports —
  "Normal keys like letters and numbers work. Backspace does
  not work and nor does enter/return."  No resolution.
- emscripten-discuss thread (Floh, sokol author, June 2020):
  "[the hidden input approach] kinda works, but it has all
  sorts of problems... don't expect it to work for more than
  six months after a browser update breaks something."
  Eventually drew their own on-screen keyboard.
- emscripten SDL2 issue #80: still open, still no clean
  virtual keyboard support.
- zhobo63/imgui-ts (most successful imgui-web for mobile):
  uses VISIBLE overlay `<input>` / `<textarea>` positioned
  on top of the widget — user sees the native input.
  Different UX trade-off; doesn't have most of our bugs but
  reveals the wasm-rendered widget as decorative.

zimr's hidden-input approach matches the community's
"standard hack."  The known limitations of the standard hack
apply.  Don't waste turns trying to fix without a new idea.

**Known limitations:**

- **First-tap-doesn't-pop-keyboard.**  On iOS Safari, the
  first tap of a session may not pop the keyboard because
  the wasm-side `el.focus()` happens one rAF after the touch,
  outside the gesture context iOS requires.  Turn 285 added a
  touchstart pre-focus + 60ms blur fallback to work around
  this, but turn 291 removed it because (a) it caused a
  keyboard flash on every non-text tap (Add button blinking,
  Simon turn 291) and (b) the 60ms blur raced wasm's rAF
  tick under load.  Sokol's notes confirm Android allows
  non-gesture focus() — so the pre-focus only helps iOS at
  the cost of Android UX.  Workaround: tap anywhere first.
  Filed in followups; not blocking.  Future-fix candidates:
  - Hidden input at 100×100px with `opacity: 0.001`.
  - `inputmode="search"` for clearer browser signal.
  - Focus from `pointerdown` instead of `touchstart`.

- **Backspace doesn't delete text on Android Chrome.**
  Filed turn 291.  Letters/numbers type fine (the `input`
  event forwards them as codepoints), but the `keydown`
  listener for `Backspace` either doesn't fire on this IME
  or doesn't produce `e.key === "Backspace"`.  Most Android
  software keyboards send deletion via the `input` event's
  `inputType: "deleteContentBackward"` instead of a key
  event.  Future fix: listen for `beforeinput` and forward
  `KEY_BACKSPACE` (259) when `event.inputType ===
  "deleteContentBackward"`.  Same imgui-mobile bug seen in
  iss #5133.

- **Soft-keyboard scroll positioning is flaky.**  Turns
  283-287 invested heavily in `scrollFocusedWidgetIntoView`
  + canvas-shrink to bring an off-screen widget above the
  keyboard.  Works reliably for the populated-log case
  (Simon turn 285: "Ok the scroll up worked").  Flaky for
  the empty-log case where window content fits the viewport
  (`scroll_max_y == 0` makes scroll a no-op).  No clean fix
  without moving the window itself, which breaks user-owned
  window position semantics.  Accepted as known limitation.

- **Visual smoke test missing.**  Filed turn 271 — would
  have caught the baseline bug turn 277 and most of these
  keyboard quirks earlier.  Highest-leverage tooling
  investment still pending.

### Step 1.8 — Native overlay text input (replaces hidden-input hack) — ✅ DONE turn 302

Filed turn 292 after studying zhobo63/imgui-ts source.
Prototype phase 1 landed turn 293.  Polished across turns
294-301; debug HUD removed and step closed turn 302 after
Simon's phone test confirmed overlay aligned with wasm
widget, keyboard pops + stays, typing works, defocus
returns to wasm rendering with typed text intact.

**The architectural insight:**

zhobo63's `imgui-ts` is the most successful imgui binding for
mobile web (npm `@zhobo63/imgui-ts`).  Its `src/input.ts` is
~120 lines.  Key trick: instead of a hidden 1×1 input
forwarding chars to wasm, render an actual VISIBLE
`<input type="text">` (or `<textarea>` for multiline)
positioned exactly over the imgui-drawn widget, styled to
match (font, color, background).  While the field is
focused:

- The DOM input IS the text editor.
- Native browser handles keyboard, backspace, IME, selection,
  cursor, copy/paste, scroll-into-view-on-keyboard-pop.
- Each frame, the wasm side polls the DOM input's `.value`
  and writes it into the imgui-side text buffer.
- The imgui widget's own text rendering is suppressed while
  the DOM input is on top (zimr already only renders the
  buffer; the DOM input overlays it visually with the same
  bytes).

On blur (Tab, click-outside, Enter on single-line):

- `setVisible(false)` → `display: none`.
- The wasm widget resumes rendering normally.

**Why this works where hidden-input doesn't:**

- **Backspace:** real DOM input gets `deleteContentBackward`
  natively; we don't have to detect it.
- **First-tap:** focus is direct on a visible, focusable
  element — no race against wasm rAF.
- **Scroll-into-view:** browser does its native "scroll the
  focused input above the keyboard" because the input is
  real.  We don't need `scrollFocusedWidgetIntoView` at all.
- **IME:** real input, real IME support.
- **Selection:** native.
- **Copy/paste:** native.
- **Auto-complete:** native (can be disabled with attributes).

**The trade-off zhobo accepts:**

The user sees the DOM input's styling, not the imgui
widget's, while editing.  If we style the input carefully
(same font, same colors, same exact rect), the swap is
visually subtle but not invisible.  OS-specific differences:
iOS inputs have rounded corners, Android has different focus
ring, etc.

For zimr's monospace-by-default text style, the swap is
manageable.  The user briefly sees a slightly-different-but-
similar text field while editing.

**Architecture for zimr:**

Web side (`src/web/zimr.ts`):

- Replace the hidden 1×1 input with a `position: fixed`
  visible input styled to match the widget.
- New extern interface: `js_show_overlay_input_at(x, y, w, h,
  text_ptr, text_len, font_size, fg_color, bg_color)` —
  positions, styles, populates the input.
- New extern: `js_hide_overlay_input()` — defocus + hide.
- New extern: `js_overlay_input_get_text(out_ptr, max_len)`
  — wasm polls the current text each frame, returns the
  byte length written.

Wasm side (`src/ui.zig`):

In `inputTextImpl`, when `ctx.active_id == id`:
- Each frame, poll `js_overlay_input_get_text` into the
  buffer.
- Track if the input's `.value` differs from `buf` — if
  yes, write it.  This is the inverse of today's
  "wasm-side typing → buffer" path (which we keep for
  desktop where the overlay isn't shown).
- DO NOT render the buffer as text (the DOM input does).
  Optional: render an empty rectangle for the "field
  outline" so the box still looks like a widget.
- DO NOT render the cursor (DOM cursor shows).

On activation:
- Call `js_show_overlay_input_at(box.x, box.y, box.w, box.h,
  buf, len, font_size, text_color, bg_color)`.

On deactivation (Enter, click-outside, Esc):
- Call `js_hide_overlay_input()`.
- Buffer already reflects the final text (polled last frame).

**Desktop coexistence:**

Desktop's wasm-side rendering of text + cursor is the
better UX (matches the imgui visual exactly, no DOM
overlay).  Keep both paths:
- Phase 1: opt-in via a new `Style.text_input_use_overlay:
  bool = false` flag.  Demo enables it on web mobile builds
  via UA sniff or `'ontouchstart' in window`.
- Phase 2: once the overlay path is proven on phone, flip
  the default for ALL web builds.  Desktop browsers keep
  it on too — the visual difference is minor and the
  unified code path is worth it.
- Phase 3: remove the hidden-input path.

**Why not phase-merge into Step 1.7:**

Step 1.7 has shipped — the hidden-input path works on
desktop and partially on mobile.  Replacing it is a
significant architectural change with its own bugs and
polish work.  Adding Step 1.8 as a successor lets us:
- Keep 1.7 as a working fallback while 1.8 stabilizes.
- Have a clean changelog when 1.8 replaces 1.7.
- Test the two side-by-side on the same phone in the
  same session.

**Implementation order (proposed):**

1. **Prototype turn 293:** add the overlay input alongside
   the hidden input.  Style it minimally (just position +
   visible).  Make the demo opt-in via a checkbox in
   log_viewer.  Verify: typing works, backspace works,
   first-tap works on Android.
2. **Polish turn 294:** match font/colors to zimr style.
   Make the swap visually smooth.  Test on more demos.
3. **Default-flip turn 295:** make overlay the default on
   web; hidden-input becomes opt-out.
4. **Cleanup turn 296+:** remove hidden-input path, the
   visualViewport canvas-shrink (browser handles it), and
   `scrollFocusedWidgetIntoView` (browser handles it).

**Net code change estimate:**

- +120 lines TS for the overlay implementation (mirrors
  zhobo's `input.ts`).
- +50 lines Zig for the text-poll-back path.
- -200 lines TS once cleanup completes (hidden input + its
  key forwarders + visualViewport shrink).
- -60 lines Zig once cleanup completes
  (`scrollFocusedWidgetIntoView` and its restore).

**Net: smaller codebase, more capability.**

**Known limitations (accepted, turn 295):**

- **First-touch on a fresh page does not pop the keyboard on
  Android Chrome.**  Confirmed by Simon turn 295 on Android.
  Cause is some combination of (a) the page lacking sticky
  user-activation before the first gesture, and (b) the
  wasm-side rAF callback running outside the gesture task
  by the time `overlay.focus()` is called.  zhobo63/imgui-ts
  has the same issue (same architecture).  We tried:

  - Pre-focusing the canvas on page load (turn 295) — no effect.
  - Eagerly creating the overlay element on page setup (turn 295)
    — no effect.
  - Pre-focusing the hidden input on every touchstart (turn 285,
    reverted) — caused keyboard blinking on non-text taps.

  Path forward (deferred): a synchronous "predict activation"
  wasm export called from inside touchstart that lets JS focus
  the overlay in-gesture-context for taps that will activate a
  text widget.  ~half-day's work, but invasive.

  Workaround: user taps anywhere first, then taps the text
  widget.  The "Top" / "Clear" buttons on log_viewer happen to
  serve this purpose.  Acceptable cost.

- **Stretch-mode hit-test silently misses** when
  `canvas.clientWidth != cfg.window.width`.  Mouse arrives in
  CSS pixels but stretch-mode widgets lay out in cfg-logical
  pixels.  Not specific to Step 1.8 but exposed by overlay
  positioning, which made the disagreement visible.  See
  claude.md "Coordinate systems" for the table.  Fix candidates:
  convert mouse to logical at push time (small), or eliminate
  stretch's separate coord space (clean but breaks back-compat).
  Filed for a future turn.

### Phase 1 boundary

Add a `Filters & Selection` tab to `ui_full_showcase.zig` covering
steps 1.1–1.3.  (1.4 and 1.5 land their own spotlight in
`ui_panes.zig`.)

---

## Phase 2 — Dev tools (2 steps)

v2 placed these at Phase G end.  Pulling forward saves debugging
cost across flag-wave and cleanup phases — when an item ID hashes
weirdly during E or F, opening IDStackTool beats grepping source.

### Step 2.1 — `showMetricsWindow` + `showAboutWindow`

Metrics: frame timing, draw-call count, vertex/index counts, widget
category counts, hovered/active item IDs, window list, style
preview.  Lives as a panel on `imgui_demo.zig`.

About: zimr version, contributors, license info.  Static.

### Step 2.2 — `showDebugLogWindow` + `showIDStackToolWindow` + long-press bridge

DebugLog: rolling buffer of `dom.log` output, filter-by-level.
Pairs naturally with the TextFilter from 1.2.

IDStackTool: click any widget, see its hash chain back to root.

**Long-press → right-click bridge lands here.**  Filter context
menu is the first feature that wants it.  ~20 LOC in
`runtime/input.zig`: track touch-down position + time; on release
after >500ms with <8px movement, synthesize a right-click event
at the original position.  Threshold + enable toggle on `Frame.input`
so demos can opt out.

---

## Phase 3 — Flag-extension waves (6 steps)

The bulk.  ~290 flags across 15+ enums.  Decision rule per group:

- **Mutually exclusive (only-one-active-at-a-time)** → Zig enum.
  Caller can't construct an inconsistent state.
- **Independent (any subset valid)** → bool fields on `Opts`.

Each step ships one `ui_<group>_flags_tour.zig` demo that toggles
every flag side-by-side, plus extends the relevant `Opts` struct.
Internal-only imgui flags (`ChildWindow`, `Popup`, etc.) skipped —
they're imgui implementation detail, not public surface.

### Step 3.1 — `WindowFlags` (30) + horizontal scroll API

`WindowOpts` grows: `no_title_bar`, `no_resize`, `no_move`,
`no_scrollbar`, `no_collapse`, `always_auto_resize`, `no_background`,
`menu_bar`, etc.  `no_decoration` as a composite bool.

Bundles the X-axis scroll API deferred from v2 A1: `getScrollX`,
`setScrollX`, `setScrollHereX`, horizontal scrollbar rendering,
`horizontal_scrollbar` window flag.

**Demo:** `examples/ui_window_flags_tour.zig` — checkbox grid
toggling each flag with a sample window reacting live.

### Step 3.2 — `TableFlags` (35) + `TableColumnFlags` (23)

`TableSizing` enum (4 mutually-exclusive flags collapsed).
`TableColumnSizing` already exists.  Bools for resizable,
reorderable, hideable, sortable, scroll_x, scroll_y, borders_*,
etc.

**Demo:** `examples/ui_tables_advanced.zig` — drag-to-reorder
columns + hide-via-context-menu (uses long-press bridge from 2.2)
+ per-column sort policies.

### Step 3.3 — `InputTextFlags` (27) + `ColorEditFlags` (29)

`InputTextOpts` grows: chars_decimal, chars_hex, password,
read_only, auto_select_all, enter_returns_true, escape_clears_all,
etc.  Several were prepared by A4's callback infra.

`ColorEditFlags`: `ColorDisplay` / `ColorInput` / `ColorOutput`
enums for the exclusive groups; rest as bools.

**Demo:** `examples/ui_input_advanced.zig` — password mask toggle,
decimal-only, hex-only fields; ColorEdit display-mode comparison
grid.

### Step 3.4 — `TreeNodeFlags` cleanup + `SelectableFlags` + `SliderFlags` + `ButtonFlags`

Tree flags partially in 1.5; this step finishes the rest.
Selectable: `dont_close_popups`, `span_all_columns`,
`allow_double_click`, `disabled`, etc.
Slider: `logarithmic`, `no_input`, `wrap_around`, `always_clamp`,
etc.
Button: most are already covered by the `MouseButton` enum on the
existing signature; add the rest (e.g. `enable_nav`).

**Demo:** `examples/ui_widget_flags_tour.zig`.

### Step 3.5 — `HoveredFlags` + `FocusedFlags` + `PopupFlags` + `ComboFlags` + `ChildFlags`

`HoverDelay` enum (`none | short | normal`).
`ComboHeight` enum.
Independent bools for the rest.

**Real work hidden under "flag":** hover-delay requires
per-item-id hover-start timestamp state on `UiContext`.  Not just
bool plumbing.

**Demo:** `examples/ui_hover_focus_flags_tour.zig` — interactive
delay tweaker; tooltip behavior side-by-side with each flag combo.

### Step 3.6 — `TabBarFlags` + `TabItemFlags` + `DragDropFlags` + `ItemFlags`

`TabFittingPolicy` enum.  Otherwise mostly bools.  ItemFlags
affects every widget — threading care needed.

**Demo:** `examples/ui_tabbar_dragdrop_polish.zig` — reorderable
tabs + drag-to-merge between sources.

### Phase 3 boundary

Add a `Flags & Polish` tab to `ui_full_showcase.zig` linking to
the six tour files for deeper exploration.

---

## Phase 4 — Tier-3 cleanup (4 steps)

The many-small-functions cluster.  Less architectural risk; each
is its own little decision.

### Step 4.1 — Table queries + cell bg + angled headers

`tableSetColumnIndex`, `tableHeader`, `tableAngledHeadersRow`,
`tableGetColumnCount/Index/Name/Flags`, `tableSetColumnEnabled`,
`tableSetBgColor` (cell + column variants), `TableRowFlags` +
`TableBgFlags`.

**Demo:** extend `ui_tables_advanced.zig` (from 3.2) with runtime
column visibility checkboxes + angled headers showcase.

### Step 4.2 — Layout/cursor/item-query gaps + drag ranges + color convert + checkbox flags

~15 small fns: `setCursorScreenPos/PosX/PosY`,
`getCursorPosX/Y/StartPos`, `getTextLineHeight*`,
`getFrameHeight*`, `isAnyItemHovered/Active/Focused`,
`isItemToggledOpen`, `setItemDefaultFocus`,
`setNextItemAllowOverlap`, `isRectVisible`, `getItemFlags`,
`dragFloatRange2`, `dragIntRange2`, color converters (4 fns —
**as methods on `Color`**, ambition marker), `checkboxFlags`.

**Demo:** new `examples/ui_query_grab_bag.zig` — every newly-exposed
query API surfaced in a debug HUD.

### Step 4.3 — `KeyboardKey` selective expansion + popup variants + theme presets + about/userguide/styleSelector/version

`KeyboardKey` grows from 35 to ~65 keyboard-shaped values: F13–F24,
RightShift/Ctrl/Alt-as-keys, NumPadEnter, NumPad operators,
Pause, ScrollLock, etc.  Mouse buttons + gamepad stay on their own
typed enums.

New: `openPopupOnItemClick`, `beginPopupContextWindow`,
`beginPopupContextVoid`, `tabItemButton`, `setTabItemClosed`.

New themes: `Style.light_default`, `Style.classic_default`.

New: `showAboutWindow`, `showUserGuide`, `showStyleSelector`,
`showFontSelector`, `getVersion`.

**Demo:** `examples/ui_keys_themes_tour.zig` — theme switcher +
key-chord HUD + each `show*` toggle.

### Step 4.4 — int↔f32 ceremony cleanup (discovered turn 278, refined turns 279/280)

zimr's codebase has **827 sites** of `@as(f32, @floatFromInt(X))`
mostly written when result-location inference was less aggressive
in earlier Zig versions.  Zig 0.16 lets most of the ceremony go.

**Full migration reference: `src/notes/zig-0.16-migration-guide.md`**
— see its "Cleanup decision tree" section for which form fits
which site shape.

**Preferred form (turn 280):**

    // BEST in 0.16 — `@floor` returns int directly when result-location
    // is typed int, AND propagates f32 inward to coerce the int operand:
    const px: i32 = @floor(int_var * scale);

    // Pre-0.16 form:
    const px: i32 = @intFromFloat(@as(f32, @floatFromInt(int_var)) * scale);
    // Turn 279 cleanup:
    const px: i32 = @intFromFloat(int_var * scale);

`@floor` is preferred over `@intFromFloat` for pixel math because
it rounds toward -∞ (matches human-expected rounding at negative
coordinates) rather than toward 0.  For non-negative inputs they
agree; using `@floor` future-proofs sites where negative offsets
might appear.

Per-file scope (sites of `@as(f32, @floatFromInt`):

- `src/drawing.zig`         — 267
- `src/ui.zig`              — 56
- `src/rlsw_pixel.zig`      — 29
- `src/rlsw.zig`            — 22
- `src/render.zig`          — 18
- `src/math.zig`            — 18  (vendored zmath — DON'T edit per
                                   the math.zig Z0 header)
- `src/codecs.zig`          — 17
- `examples/rlsw_side_by_side.zig` — 9
- `src/types.zig`           — 8

NOT a mechanical sed:

- Sites passing the conversion result to an `anytype` parameter
  can't drop the explicit `@as(f32, ...)` — Zig can't infer
  through `anytype`.
- Sites with no result location at all (top-level `var x = ...`
  with no type annotation) need the explicit `@as`.
- Sites inside `@as(SomeOtherType, ...)` — already explicit, leave
  alone.
- math.zig is the vendored zmath fork; skip per its Z0 header
  comment.

Per claude.md's "every line you touch must become clearer" rule
(turn 278), the right way to land this is INCREMENTALLY: when
editing any file with these sites, clean up the ones you pass.
Resist the temptation of a one-turn mass sed.

**Demo:** none — this is a codebase-hygiene sweep, no user-facing
surface change.

#### Refinement turn 279 — verified Zig 0.16 rules

Tested against the actual `0.16.0` compiler — the rules are more
nuanced than "result-location propagates everywhere":

1. **`@as(T, @intCast(x)) → @intCast(x)`** in typed slots
   (`const i: i32 = ...`, struct field init, return statements).
   Same for `@floatFromInt`, `@floatCast`.

2. **`@intFromFloat(@as(f32, @floatFromInt(x)) * scale)
   → @intFromFloat(x * scale)`** — the highest-value case.
   `@intFromFloat` propagates its f32 result-location INWARD
   through the multiplication, so `x` (any int) coerces to f32
   inside the `*`.

3. **Implicit `int → f32` ONLY when LOSSLESS.**  Verified:
   `const a: f32 = i16_var` compiles; `const a: f32 = i32_var`
   errors ("expected type 'f32', found 'i32'").  i16/u8/u16 fit
   in f32's 23-bit mantissa; i32/usize/i64 don't.  Most zimr code
   uses i32 and usize, so the bare-coerce form is rare here.

4. **Binary `*` `+` `-` `/` DO NOT propagate result-location to
   operands.**  So `const t: f32 = i32_var * f32_var` errors —
   you must either explicit-convert the int or wrap in
   `@intFromFloat(...)` to leverage rule 2.

### Step 4.5 — `@as(T, @intCast(x))` / `@as(T, @floatCast(x))` cleanup (filed turn 279)

Sister sweep to step 4.4.  ~99 sites in `src/` of the pattern
`@as(i32, @intCast(x))` etc. that became redundant in Zig 0.16
via the same result-location propagation.

**Per-file scope of `@as(T, @intCast(...))`:**

- `src/drawing.zig`         — 43
- `src/rlsw.zig`            — 10
- `src/rlgl.zig`            — 10
- `src/math.zig`            — 10  (skip — vendored zmath)
- `src/ui.zig`              —  9
- `src/runtime.zig`         —  6
- `src/rlsw_pixel.zig`      —  6
- `src/entities.zig`        —  5

Plus ~5 sites of `@as(T, @floatCast(x))`.

Same incremental-cleanup rule as 4.4: clean what you touch; no
mass sed.

**Demo:** none.

### Step 4.6 — Speed up `build_standalone.py` via `-Dfocus` for install — ✅ DONE turn 278

**Status: shipped.**  Filed as pending in turn 279 by mistake —
turn 281 noticed the build script output already said "(focus
filtered)" and the wiring was in `build.zig` + `build_standalone.py`
all along.  Implementation predated the filing.

Verified turn 281: `python3 scripts/build_standalone.py ui_log_viewer`
takes ~7s cold after a `ui.zig` change (vs the projected 50s
without focus).  Reads "ReleaseSmall (focus filtered) ..." in
the build log.

Lives in:
- `build.zig:296-385` — `-Dfocus` option declared, `matchesFocus`
  helper, install-step dependency gated on focus.
- `scripts/build_standalone.py:249-251` — passes
  `-Dfocus={example}` to `zig build install`.

Kept the section for arc-history clarity (delete during plan v3
archive at Phase 6 close).

---

## Phase 5 — Persistence + niche-but-real (3 steps)

The features that aren't blocked on anything earlier.  Persistence
is the headline; the other two are real renderer/tooling primitives
that imgui ships.

### Step 5.1 — Persistence (HN demo)

**The most "we did it better than imgui" moment in the arc.**

Zig side:
- `UiContext` gains `persistence_key: ?[]const u8`.  When set,
  layout state (window positions, sizes, collapsed, table column
  order/widths, last-selected tab, scroll positions) serializes
  to `.zon` every N frames or on `endFrame` (TBD inline).
- `Ui.addPersistenceHandler(name, save_fn, load_fn)` for
  user-defined chunks (per-app extra state).
- `extern fn save_layout(key_ptr, key_len, value_ptr, value_len)`
  and `extern fn load_layout(key_ptr, key_len, out_buf, out_buf_len) usize`
  in `web.zig`.

TypeScript side (`src/web/zimr.ts`):
- `save_layout` → `localStorage.setItem("zimr_layout_<key>", zon_string)`.
- `load_layout` → `getItem`, copy bytes into out_buf, return length.
- Error handling: quota exceeded, missing key, malformed zon all
  return 0-length (caller starts fresh).

**Demo:** `examples/ui_persistence.zig` — drag the window, change
the splitter position, hide a column, refresh the page.
Everything's where you left it.  The screenshot for the eventual
HN post.

### Step 5.2 — Logging family

`logToConsole(auto_open_depth)` (replaces imgui's `logToTTY`, since
wasm has no TTY but `console.log` is the equivalent).
`logToClipboard(depth)` — uses the clipboard infra from A1.
`logFinish`, `logButtons`, `logText(fmt, args)`,
`logSetNextTextDecoration(prefix, suffix)`.

Internal: tee draw-list submission strings into a log buffer when
logging-enabled.

**No `logToFile`** — wasm has no fs.  Could add a "Save log as
.txt download" via the JS bridge if a use case appears.

**Demo:** `examples/ui_logging.zig` — three buttons (console /
clipboard / debug log window from 2.2) + sample window whose
contents get logged.

### Step 5.3 — DrawListSplitter

`DrawListSplitter { split(n), setCurrentChannel(idx), merge() }`.
Used internally by tables for cell-content-vs-row-bg z-order;
exposed publicly for the same kind of layered-widget pattern.

**Demo:** `examples/ui_drawlist_splitter.zig` — concentric rings or
layered bars showing ordered merge of submissions made in arbitrary
order.

---

## Phase 6 — Capstone close (1 step)

### Step 6.1 — Final `ui_full_showcase` polish + arc archive

Because the showcase was updated incrementally at each phase
boundary, this step is light:

- Polish all tabs; re-validate every star rating; refresh manifest
  descriptions.
- Full CHANGELOG arc-close entry referencing every phase.
- Move `imgui-plan.md` to `src/notes/archive/`.
- Update `PLAN.md`: imgui row complete; status snapshot refreshed
  (test count, example count, smoke count).
- Regenerate cheatsheet one final time.

---

## Cross-cutting concerns

### Per-step deliverables

- Code in `src/ui.zig` (or sibling), following the 13 style rules.
- Each new public API gets host unit tests.
- Each new feature has a demo per the mixed-granularity model:
  standout demos get their own file; smaller features extend
  existing files; flag-wave tours get one tour file each;
  `imgui_demo.zig` grows panels alongside.
- Each demo registers in `build.zig` + `manifest.json`.
- Standalone built and presented via `present_files` for phone
  testing.

### Audit gate per turn (no exceptions)

- `zig build test` green.
- Focused smoke if any example touched
  (`zig build smoke-test --release=small -Dfocus=<arc>`).
- `zig fmt --check src/ examples/` clean.
- `python3 scripts/count_globals.py` → 0/0/0.
- `python3 scripts/check_dag.py` → no new SCCs.
- Test count delta documented in changelog.

### Cheatsheet regeneration

At each phase boundary: `python3 scripts/build_cheatsheet.py`.
The cheatsheet auto-parses from sources, so it picks up new methods
without manual editing.

### Capstone incremental updates

Each phase boundary adds one tab to `ui_full_showcase.zig`.
Phase 6 is polish, not assembly.

### Phone testability

Every demo runs under `.responsive` scale where interaction matters.
Tap targets ≥48 CSS px.  Right-click features rely on the long-press
bridge from 2.2.  Standalone build at end of each turn so Simon
can phone-test.

---

## Where we might surprise ourselves

The directive: "be on the lookout for clever ways to make zimr a
better system than imgui."  Places where this might land mid-arc
(beyond the ambition markers already in the plan):

- **Capstone as a persistent app.**  Once 5.1 ships, `ui_full_showcase`
  could remember which tab you were on across page loads.  Tiny touch,
  big "this feels alive" effect.

- **`std.zon` everywhere a config is needed.**  Not just persistence —
  anywhere imgui uses a text-config-string, a `.zon`-parseable form
  reads better and is parseable from Zig in one stdlib call.  Watch
  for opportunities during the flag waves.

- **Better text-rendering primitives.**  Subpixel positioning?
  Signed-distance fields for crisp scaling across zoom levels?
  Out of scope for this arc but worth a note.

- **Touch-first widgets.**  Swipe-to-dismiss tabs?  Two-finger pinch
  on tables?  Pull-to-refresh for data lists?  Out of scope here
  but candidates for a future "phone-native" arc.

- **Audio integration.**  Slider that hums while dragging?  Button
  with a satisfying click via the audio device?  Tiny but charming.

These aren't planned for this arc; they're flags to raise if
something obvious shows up while doing the work.  The arc's job is
parity-plus-six-ambition-markers; further "more than imgui" is a
future arc.

---

## Deferred / out of scope

- **Multi-viewport.**  Paradigm-incompatible with browser canvas.
- **Allocator hooks.**  zimr's `gpa`-arg model already covers what
  imgui's allocator override does; replacing it with a global override
  is anti-Zig.
- **`V*` va_list variants.**  Zig has comptime + tuple args;
  va_list isn't a Zig primitive.
- **IME.**  Paradigm-incompatible; browser handles input composition
  above the canvas.
- **`io.ConfigFlags_DockingEnable`-style runtime feature gates.**
  zimr features either exist or they don't; no runtime feature-flag
  layer.

## Filed for future steps

- **Step 1.3 — Nestable MultiSelect scopes.**  Skipped in MVP
  (turn 303 rubberduck decision).  Imgui supports nested
  Begin/End/Begin/End/End/End via a stack
  (`g.MultiSelectTempData`, `g.MultiSelectTempDataStacked` —
  `imgui_widgets.cpp:8000-8002`).  Zimr MVP ships a single
  active-scope slot.  Adding stack support later is non-breaking
  (single slot becomes "stack of 1" semantically).  Revisit if a
  demo needs nested scopes — most likely candidate is a future
  "tag editor inside item list" pattern.

- **Step 1.3 — `SelectionBasicStorage` index→ID adapter.**  Skipped
  in MVP (turn 303 rubberduck decision).  Imgui's
  `AdapterIndexToStorageId` callback lets users store selection by
  persistent ID while the multi-select API still uses indexes for
  iteration; it's documented as optional even in imgui itself.  For
  zimr the maximally Zig-idiomatic shape is probably comptime:
  `SelectionBasicStorage(Adapter)` where `Adapter` is a comptime
  type with `fn adapt(idx: u64) u64` — duck-typed at the call site,
  zero indirection at runtime.  This would shine in a demo where
  the item list is *reorderable* (sortable column header, filter
  bar, search) and selection needs to survive the reorder — e.g.
  the file-tree in Step 1.4's `ui_panes.zig`, or a future
  searchable picker.  Add the adapter when a demo demands it;
  identity is the current behavior so the addition is non-breaking.

- **Step 1.4 — `setWindowCollapsed(name, bool)` named variant.**
  Skipped turn 307: zimr's `Window` doesn't yet have a `collapsed`
  field nor the title-bar tap-toggle rendering path that would
  back it.  Adding collapsed-window support is its own
  multi-piece feature (struct field + chrome render + tap handler
  + body-skipped layout path), not just an API addition.  File
  for a future "Window chrome polish" step.

- **Step 1.4 — `setNextWindowSizeConstraints` custom-callback
  variant.**  Imgui supports a callback for non-rectangular
  constraints (aspect ratio, snap-to-grid).  MVP ships only
  rectangular min/max bounds.  Add the callback when a demo
  needs it; the API extension is non-breaking (add an opts
  param).

- **Step 1.4 — `Cond` enum (Always / Once / FirstUseEver /
  Appearing) for `setWindow*` family.**  MVP ships Always-only
  semantics — every call applies unconditionally.  Imgui's Cond
  gating is most useful for `setNextWindow*` initialization
  ("set this size unless the user has resized it themselves").
  zimr's `initial_pos` / `initial_size` already cover
  FirstUseEver intent at window-creation time, so the named
  `setWindow*` variants are positioned as "I want to control
  this from outside" — Always-semantics matches that intent.
  Add Cond if/when a demo specifically wants a one-shot
  setWindowSize.

---

## Where this plan can change

Deviations welcome when better-justified.  Most likely to shift:

- **Step ordering within a phase** if dependencies surface
  differently than expected.
- **Step splitting** if a step turns out 2× larger than estimated.
- **Demo file boundaries** if a planned new file turns out to
  belong as a panel on an existing file or vice versa.
- **Enum naming** in flag-wave steps — first decision sets the
  convention; later steps follow it.

The plan's anchor stays fixed: every imgui feature gets a zimr
equivalent; every feature has a demo; every step ends at a saved
zip you can test on phone.
