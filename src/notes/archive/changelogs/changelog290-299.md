# CHANGELOG — turns 290-299

Per-turn journal for turns 290-299.  Prepend new entries after the
`## [Unreleased]` line; do not edit existing entries.  When turn 300
opens, this file is frozen and a fresh `changelog300-309.md` starts.

Earlier turns: see the sibling files in this directory
(`changelog280-289.md`, `changelog270-279.md`, `changelog260-269.md`,
`changelog250-259.md`, `changelog240-249.md`, `changelog230-239.md`,
`changelog220-229.md`, `changelog210-219.md`, `changelog200-209.md`,
`changelog093-199.md`, `changelog001-092.md`).

---

## [Frozen at turn 300]

### Turn 299 — Step 1.8: body bg matches canvas — soft-keyboard seam vanishes

Simon's screenshot turn 299 caught a cosmetic seam I hadn't
noticed: when the keyboard pops, the visualViewport canvas-
shrink reduces `canvas.style.height` to ~visible viewport
height.  The page body shows through in the gap between
canvas-bottom and keyboard-top.

Body had `background: #020617` (dark navy), canvas had
`#0f172a` (dark slate).  Both dark, but visually distinct — the
gap looked like a "big dark blue zone around the textfield"
during keyboard interaction.

**Fix:** set body bg to `#0f172a` (matching canvas).  The
shrink-gap is now invisible.  Two files:
- `src/web/host.html` — used for the multi-example dev page
  served from `zig-out/web/`.
- `scripts/build_standalone.py` — embedded template for
  `prebuilt/standalone/<example>.html`.

Left `src/web/index.html` (the gallery / module listing page)
alone — that's a content page, not a fullscreen canvas demo;
its `--bg: #020617` is intentional and isolated from canvas
sizing concerns.

**This is the cosmetic cleanup that closes Step 1.8.**

Recap of the full Step 1.8 arc (turns 292-299):

- **Turn 292:** studied zhobo63/imgui-ts.  Architecture: visible
  DOM overlay positioned over widget, browser handles editing.
- **Turn 293:** prototype shipped.  Backspace, IME, scroll-into-
  view all work natively.
- **Turn 294:** cleanup — removed dead `scrollFocusedWidgetIntoView`
  helpers, saved_scroll field.
- **Turn 295:** scale-mode-aware coord conversion
  (`wasmRectToCss`), documented coord systems in claude.md,
  filed first-touch as accepted limitation.
- **Turn 296:** clip overlay to window content rect to handle
  scroll-out-of-window case.
- **Turn 297:** added canvas-bound clip + visible debug HUD.
  Canvas-bound clip turned out to be wrong.
- **Turn 298:** reverted canvas-bound clip (it caused keyboard-
  pops-then-immediately-dismisses).  HUD screenshot proved the
  coord conversion was correct all along; the "size wrong"
  reads were optical illusions of a sparsely-populated canvas.
- **Turn 299** (this turn): body-canvas bg match closes the
  last visible cosmetic issue.

**Step 1.8 is ✅ DONE.**  Remaining known limitations all filed:
first-touch on fresh page, stretch-mode hit-test mismatch.
Both acceptable trade-offs.

**Still to clean up next turn (turn 300, rolling into new
decade):**
- Flip `DEBUG_OVERLAY_COORDS = false`.
- Remove `ensureCoordHud` + HUD update block (~30 lines).
- Mark Step 1.8 ✅ in `imgui-plan.md`.

**Audit:**

- `zig build test`: 1389 / 1389 PASS.
- Standalone built focus-filtered.  Verified both `background:`
  lines now read `#0f172a`.

**Files touched (3):**

- `src/web/host.html` — body bg `#020617` → `#0f172a` with
  explanatory comment.
- `scripts/build_standalone.py` — same change in the embedded
  template.
- `src/notes/changelogs/changelog290-299.md` — this entry.

**Next turn (300):** Decade rollover.  Freeze this changelog,
start `changelog300-309.md`.  Turn 300 actions: HUD cleanup,
Step 1.8 promotion to ✅, then onto Step 1.3 (MultiSelect +
SelectionBasicStorage).

---

### Turn 298 — Step 1.8: revert turn-297's canvas-bound clip (caused keyboard-pops-then-immediately-dismisses)

Simon's HUD screenshot turn 297 nailed the diagnosis:

```
SHOW wasm box 16,418 311×32 fp=16
  → css 16,418 311×32 fp=16.0
canvas client 411×861 backing 1079×2260
wasm screen 411×861  dpr=2.625
```

Two things this confirms retroactively:

1. **Coord conversion is correct** — wasm passes 311×32 CSS px,
   helper returns 311×32 CSS px (identity in responsive mode),
   widget visually IS 311×32 on the canvas.  The "overlay too
   big" perception from earlier turns was me misreading
   screenshots — the overlay's actual size matches the widget
   exactly.  Step 1.8 base case has worked from turn 293 on.

2. **Turn-297's canvas-bound clip backfires.**  Sequence:
   - Tap filter, canvas full 861.
   - `showOverlayInput` fires, HUD displays correct values.
   - JS focuses the input → keyboard begins to pop.
   - visualViewport listener IMMEDIATELY shrinks
     `canvas.style.height` to ~400 (post-keyboard visible
     viewport).
   - Wasm reads new canvas_h ~400 on the next frame.
   - Per-frame `clipWidgetBoxToWindow` (turn 297 version with
     canvas-bound intersection) sees widget at y=418 vs
     canvas_h=400 → null → `hideOverlayInput`.
   - Hide blurs the input, dismisses the keyboard.
   - Symptom: "keyboard appears but disappears immediately."

**Fix:** reverted `clipWidgetBoxToWindow` to turn-296's
window-content-only clip.  Removed the canvas-bound
intersection.  Block comment in the helper now explicitly warns
against adding canvas clip back without coordinating with the
visualViewport shrink.

Trade-off: the bug from turn 296 image 1 (window dragged so
widget is past canvas bottom) may not be fully caught by the
window-content clip alone.  Simon hasn't confirmed turn 296's
fix on that scenario.  If it reproduces, the right strategy is
to clip against `pre-keyboard-canvas-height` (tracked through
the visualViewport listener) rather than the live shrunken
value.  Filed as Step 1.8 followup.

**Kept this turn:**

- DEBUG_OVERLAY_COORDS still true; HUD still in place.  Useful
  for the next iteration regardless.
- visualViewport canvas-shrink listener still in.  Removing it
  is a bigger change with its own risks (widgets behind the
  keyboard become unreachable for non-text interactions).

**Why the perception of "still wrong size" turned out to be
wrong:**

Looking again at the turn-297 screenshot (the "warn|" image)
through the lens of the HUD's confirmed-correct values:

- Phone is 411 CSS wide, 861 CSS tall.
- Widget is at (16, 418) sized 311×32 CSS px.
- 311 CSS px is most of the 411-wide canvas — appears as a wide
  bar.
- 32 CSS px is genuinely thin — but on a 2.625× DPR screen,
  that's 84 backing px, which subjectively looks like a
  reasonable text field height.
- The screenshot context (no other widgets visible, large
  empty canvas above/below) made the field LOOK
  disproportionately large compared to my mental model.  It's
  not.

The earlier "3× too big" reads were the same illusion —
combined with the legitimate window-clip bug fixed turn 296.

**Audit:**

- `zig build test`: 1389 / 1389 PASS.
- Standalone built focus-filtered.

**Files touched (2):**

- `src/ui.zig` — `clipWidgetBoxToWindow` reverted to window-only
  clip.  Block comment expanded with the turn-297 rationale +
  warning.
- `src/notes/changelogs/changelog290-299.md` — this entry.

**Next turn:** Simon tests; expected outcome:
- First touch still doesn't pop keyboard (accepted limitation).
- Second touch pops keyboard, overlay shows correctly sized,
  typing/backspace work.
- Tap Done → keyboard dismisses, overlay hides.
- If all that's true → flip DEBUG_OVERLAY_COORDS = false, remove
  HUD code, mark Step 1.8 ✅ DONE, move to Step 1.3.

---

### Turn 297 — Step 1.8: clip against visible canvas too + visible debug HUD

Simon's turn 296 phone test: overlay STILL appears as a big blue
rectangle floating between "Top" button and the keyboard.  This
turn's screenshot shows the issue more clearly — the filter widget
is NOT visible as wasm-rendered geometry (no input field drawn in
that space), only the DOM overlay shows.

Diagnosis (turn 297): my turn-296 `clipWidgetBoxToWindow` was
checking against the WINDOW's content clip but not against the
CANVAS's visible bounds.  When the user drags the imgui window so
its bottom extends past the canvas's CSS bottom (or visualViewport
shrink drops the canvas's bottom above the window's bottom), a
widget inside the window's content area can still fall past the
canvas's drawn region.

- Wasm side: GL viewport clips the wasm draw to canvas-backing
  bounds, so the widget is invisible.
- DOM side: `position: fixed` overlay is positioned in the gap
  between canvas-bottom and keyboard-top, where there's no canvas
  but the viewport is still there.

**Fix:** `clipWidgetBoxToWindow` now clips against TWO rectangles:
window content (as before) AND canvas visible bounds
(`0..ctx.canvas_w, 0..ctx.canvas_h`).  Intersection of both.  If
empty, the helper returns null and the overlay hides.  Comment
block in the helper documents both layers explicitly.

**Visible debug HUD:**

Flipped `DEBUG_OVERLAY_COORDS = true` and added a fixed-position
top-right HUD div that mirrors the same values console.log
receives — wasm box, CSS box, canvas dims, screen dims, DPR.
Phone screenshots can now self-report ground truth without
remote-devtools.  The HUD is tiny (10px monospace), green-on-
black, pointer-events: none.  Created lazily in `ensureCoordHud`.

If turn 298 confirms the clip-against-canvas fixes the visual,
flip the flag back to false and remove the HUD code (~30 lines).
Otherwise the HUD's output tells us exactly which dimension is
wrong.

**Audit:**

- `zig build test`: 1389 / 1389 PASS.
- Standalone built focus-filtered.

**Files touched (3):**

- `src/ui.zig` — `clipWidgetBoxToWindow` extended with canvas
  bounds intersection.  Comment block restructured to list both
  clip layers.
- `src/web/zimr.ts` — `ensureCoordHud` factory + HUD update in
  `js_show_overlay_input`'s debug block.  Flipped flag.
- `src/notes/changelogs/changelog290-299.md` — this entry.

**Hypotheses for what the HUD will reveal:**

1. **Window dragged off-canvas**: widget box has y past
   `canvas_h`.  My turn-297 fix should handle this; HUD shows
   `wasm.y > screen.h`.
2. **Box.height is unexpectedly large**: widget computes height
   not as `font_size + 2*pad_y` (= 32 in log_viewer) but as
   something bigger.  HUD shows `wasm.h ≠ 32`.
3. **Mode conversion broken**: HUD shows `screen.w != clientW`
   in responsive mode.  Wouldn't expect this, but possible if
   the resize handler hasn't fired yet.
4. **DPR-related**: HUD shows `clientW != backW/dpr`.

**Next turn:** Simon screenshots the HUD output; we read actual
numbers and fix the specific dimension that's wrong.

---

### Turn 296 — Step 1.8: clip overlay to window's content area + per-frame reposition

Simon's two-screenshot test in Chrome desktop-site mode nailed
the actual bug.  Compare:

- **Image 2** (window high, filter widget VISIBLE inside window):
  overlay correctly sized + positioned on the filter widget.
- **Image 1** (window dragged down, filter widget OFF-content):
  overlay appears floating below the visible window content.

The DOM overlay uses `position: fixed` with viewport coords.  It
ignores wasm-side scissor / window clip rects.  When imgui clips
the widget (because user scrolled it off-content, dragged the
window so the widget falls past its bottom, or the visualViewport
shrink pushed the window's bottom below the canvas), wasm doesn't
draw it — but the DOM overlay keeps showing at its geometric
position.

This **retroactively explains** the earlier "overlay is 3× too
big" observations from turn 293 / 295.  Same bug; the overlay was
rendering at the widget's logical position (off-content) while
the visible "Top" button etc. created the impression of a
disproportionate-sized rectangle below.  Overlay was correct size;
it was in the wrong place.

**Fix:**

- New `clipWidgetBoxToWindow(ctx, w, box)` helper in `src/ui.zig`
  that intersects a widget box with the parent window's
  content-clip rect (same formula as `windowImpl` pushes for the
  draw-list scissor).  Returns `null` if widget is fully clipped.
- New `updateOverlayInputRect(box)` extern + JS impl
  `js_update_overlay_input_rect(x, y, w, h)` — reposition only,
  no focus / value / selection changes.  Cheap (style writes).
- Both activation paths in `inputTextImpl` (setKeyboardFocusHere,
  click-focus) now check `clipWidgetBoxToWindow` before calling
  `showOverlayInput`.  Fully clipped → skip the show.
- Per-frame web edit-ops block (the existing poll loop) now calls
  `clipWidgetBoxToWindow` and either `updateOverlayInputRect` or
  `hideOverlayInput`.  So the overlay tracks window drags /
  scrolls / viewport resizes, and hides when the widget goes
  off-content.

**Subtleties:**

- `position: fixed` overlay at the clipped rect: the overlay
  shows the VISIBLE portion of the widget.  If the user scrolls
  the widget half-out, the overlay clips to the visible half.
  Acceptable — better than rendering past the window edge.
- `js_update_overlay_input_rect` reuses `wasmRectToCss` so the
  same scale-mode conversion applies.  No code duplication.
- `lineHeight` is updated each frame to match the (possibly
  clipped) height, so text vertical centering stays consistent.
- On host build, both new wrappers are comptime-guarded no-ops.

**What this DOESN'T fix:**

- First-touch on a fresh page — still requires prior gesture.
- Stretch-mode hit-test mismatch — filed in claude.md, not
  exercised by log_viewer (responsive).
- The `DEBUG_OVERLAY_COORDS` flag stays in for future debug.

**Audit:**

- `zig build test`: 1389 / 1389 PASS.
- Standalone built focus-filtered.

**Files touched (3):**

- `src/web.zig` — `js_update_overlay_input_rect` extern +
  wrapper.  ~10 lines.
- `src/ui.zig` — `clipWidgetBoxToWindow` helper +
  `updateOverlayInputRect` wrapper + 3 call sites (2
  activation + 1 per-frame).  ~30 lines net.
- `src/web/zimr.ts` — `js_update_overlay_input_rect` impl,
  ~15 lines.
- `src/notes/changelogs/changelog290-299.md` — this entry.

**Next turn:** depends on phone test.
- Works → Step 1.3 (MultiSelect + SelectionBasicStorage) is next
  in plan order.  Step 1.8 ready to promote to ✅ DONE.
- Still wrong → flip `DEBUG_OVERLAY_COORDS = true`, get console
  ground truth.

---

### Turn 295 — Step 1.8 polish: canvas pre-focus attempt + coord-system docs + first-touch accepted as limitation

Simon iteration this turn — three sub-changes:

**Sub-change 1: Canvas pre-focus + eager overlay-input create.**

Simon's observation: first-touch fails ONLY when nothing else has
been touched on the page yet.  After any prior gesture, touch on
the text widget pops the keyboard.

Hypothesis: browser "sticky user activation" or some first-focus-
event-on-page gating.  Tried two fixes in `attachInputHandlers`:

- `c.focus()` on page load.  Programmatic focus — doesn't engage
  user activation but might prime the focus pathway.
- `ensureOverlayInput(state)` eagerly.  Element exists in the DOM
  before any touch, eliminating first-call create overhead.

**Result (phone test, screenshot turn 295):** No effect.  First
touch on the text widget still doesn't pop the keyboard.  Hypothesis
disproven for Android Chrome.

**Sub-change 2: Coord-system docs + helper.**

Simon noticed (correctly, turn 295) that zimr has multiple coord
systems and my DPR-divide assumption was wrong.  `cfg.window.scale`
picks between two wasm-side conventions:

- `.responsive`: logical pixel == CSS pixel.  Conversion identity.
- `.stretch`:    logical pixel = init `cfg.window.width`-based.
  Conversion = `wasm_x × (canvas.clientWidth / cfg.window.width)`.

Plus mouse input is unconditionally pushed in CSS pixels — which
in stretch mode disagrees with widget-layout coord space (a real
hit-test bug filed as a followup).

Actions:

- **New wasm exports** `runtime_screen_width()` /
  `runtime_screen_height()` in `runtime_assembly.zig`.  Read
  `app.window.screen_width/height` — i.e. wasm's logical coord
  size in whichever mode is active.
- **New TS helper** `wasmRectToCss(state, x, y, w, h, font_px)`
  at module scope in `zimr.ts`.  Single conversion point.
  Universal formula: scale by `clientW / runtime_screen_width()`.
  Identity in responsive, stretch ratio in stretch.  Fallback to
  clientW if export missing (older builds).
- **`js_show_overlay_input`** now calls the helper.  No inline
  conversion math.  If future positioning code needs the same
  conversion, it gets to share the formula and the comment.
- **DEBUG_OVERLAY_COORDS flag** (default false).  When flipped to
  true and rebuilt, logs wasm-space rect + CSS-space rect +
  canvas dims + DPR on every overlay show.  Documented in
  claude.md as the debug recipe.
- **`canvasEventXY` doc-comment** updated with the stretch-mode
  bug warning so anyone editing mouse-coord code sees it.
- **`claude.md` got a "Coordinate systems" section** with:
  - Three-pixel-kinds table (CSS / backing / logical).
  - Mode semantics for `.responsive` / `.stretch`.
  - Conversion table (which direction needs which scale).
  - Debug recipe ("when something's off-size on phone").
- Updated the "Sharp edges" footer to point at the new section
  instead of the old DPR one-liner.

**Sub-change 3: Accept first-touch as known limitation.**

Filed in Step 1.8 of imgui-plan.md as an explicit "known
limitations (accepted)" section with:
- What we tried (canvas pre-focus, eager-create, pre-focus on
  every touchstart).
- Why each didn't work or had unacceptable cost.
- Future fix candidate: synchronous "predict activation" wasm
  export called from touchstart for in-gesture-context focusing.
- Workaround: tap anywhere first.  The Top / Clear buttons in
  log_viewer happen to serve this purpose.

Also filed the stretch-mode hit-test bug in the same section.

**Net effect this turn:**

- Test pass: 1389 / 1389.
- First-touch on phone: unchanged (still requires prior gesture).
- Overlay positioning: now mode-aware, identity in responsive,
  scaled in stretch.  Simon's screenshot showed the overlay
  still wrong-sized; needs more debugging next turn with
  DEBUG_OVERLAY_COORDS enabled to get ground truth.
- Documentation: future-Claude will not re-discover the coord-
  system trap from scratch.

**Files touched (5):**

- `src/notes/claude.md` — Coordinate systems section (~50 lines);
  updated Sharp Edges footer.
- `src/web/zimr.ts` — `wasmRectToCss` helper + DEBUG flag + use
  in `js_show_overlay_input`; eager `c.focus()` and
  `ensureOverlayInput` in `attachInputHandlers`; updated
  `canvasEventXY` comment.
- `src/web.zig` — unchanged this turn (turn 293 had the
  overlay externs).
- `src/runtime_assembly.zig` — `runtime_screen_width()` and
  `runtime_screen_height()` exports.
- `src/notes/imgui-plan.md` — Step 1.8 "Known limitations
  (accepted)" section appended.
- `src/notes/changelogs/changelog290-299.md` — this entry.

**Next turn (296):** Either flip DEBUG_OVERLAY_COORDS to see why
overlay is still wrong-sized (~3× too tall on Simon's Pixel), OR
move on to Step 1.3 (MultiSelect + SelectionBasicStorage) and
revisit overlay polish later.  Simon's call.

---

### Turn 294 — Step 1.8 cleanup: removed dead scroll-into-view helpers, saved_scroll, and the old soft-keyboard doc block

(Cleanup paired with the turn 293 overlay-input prototype.)
Removed from `src/ui.zig`:

- `InputTextState.saved_scroll` field — was capturing parent
  window scroll position at focus time for the old "scroll widget
  into view above keyboard" hack.  No longer needed; browser does
  this natively via the visible DOM overlay input.
- `scrollFocusedWidgetIntoView` helper fn — wrote the scroll
  delta to push a focused widget toward y=80 (canvas-px).
- `restoreWindowScrollAfterDefocus` helper fn — counterpart that
  restored the original scroll on defocus.
- `SOFT_KEYBOARD_SCROLL_TARGET_Y = 80` constant.
- ~60-line comment block explaining the old fixed-y-target
  rationale (kept the history in changelog285-289).
- 3 call sites of `restoreWindowScrollAfterDefocus(ctx)` in
  click-outside / web-blur-detected / native Enter-Esc paths.

Net: ~150 lines deleted, 1389/1389 PASS unchanged.  The old
hidden-input flow (kept side-by-side during turn 293's prototype)
is now fully unwired; only the overlay path remains.

Kept (still useful):
- `visualViewport` canvas-shrink listener in `attachInputHandlers`
  — `position: fixed` overlays don't move with native page scroll,
  so when the keyboard pops, the overlay can be occluded.  The
  canvas-shrink causes wasm to re-layout the window in the
  smaller visual viewport, naturally placing widgets above the
  keyboard.  Will revisit if testing shows it's redundant.

---

### Turn 293 — Step 1.8 phase 1: DOM overlay input prototype shipped

Simon: "Maximal quality demands an actual dom, yes.  Good plan,
do it"

Implemented the overlay-input architecture filed turn 292.
This is a real architectural change — not a tweak.

**Wasm side (`src/web.zig`):**

Replaced the single `js_request_soft_keyboard` extern with
four new ones mirroring zhobo's API surface:

- `js_show_overlay_input(x, y, w, h, text_ptr, text_len,
  font_px, fg_rgba, bg_rgba)` — position the visible DOM
  input over the widget rect, populate with current text,
  style with widget's font+colors, focus.  Called on widget
  activation.
- `js_hide_overlay_input()` — blur (which triggers
  display:none + visibility=false via the input's `blur`
  listener).  Called on Enter/Esc-defocus from native path,
  or click-outside.
- `js_overlay_input_is_visible() u32` — 1 if shown, 0 if
  hidden.  Wasm polls each frame to detect user-initiated
  blur (the user tapping outside, or pressing Enter on the
  mobile "Done" key — both fire `blur` JS-side, which we
  mirror to `active_id = 0` wasm-side).
- `js_get_overlay_input_text(out_ptr, max_len) usize` —
  copy the DOM input's `value` into wasm memory as UTF-8
  bytes, return byte count.  Wasm polls each frame.

**TS side (`src/web/zimr.ts`):**

- Renamed `softKeyboardInput → overlayInput` (visible now,
  not hidden), added `overlayInputVisible: boolean` to
  track display state.
- New `ensureOverlayInput(state)` factory:
  - `<input type="text">` with `position: fixed; z-index:
    999; display: none` (until first show).
  - `enterKeyHint = "done"` — mobile keyboard's submit
    reads "Done".
  - `blur` listener: hide + flag invisible.
  - `keydown` listener: Enter / Escape → blur.
  - Appended to `document.body` (not canvas's parent) so
    `position: fixed` works against viewport.
- New `js_show_overlay_input` implementation: applies font/
  color/bg style each call, populates `value` from wasm
  buffer (via `readString`), positions to widget rect,
  sets `display: block`, focuses, places cursor at end.
- New `rgbaU32ToCss(rgba)` helper converts zimr's packed
  `0xAABBGGRR` u32 to a CSS `rgba()` string.
- TextEncoder for `js_get_overlay_input_text` — uses the
  shared `state.encoder` (consistent with `writeString`).
- Removed `js_request_soft_keyboard` and the hidden-input
  factory entirely.  Removed the touchstart pre-focus
  hack (was already trimmed turn 291 but flagged in case
  any leftovers crept back; clean).
- Kept `visualViewport` canvas-shrink listener — still
  useful for ensuring widget layout fits the visible
  viewport when keyboard is up, even with the overlay
  doing native scroll-into-view.

**`src/ui.zig` — `inputTextImpl`:**

The widget logic now has an explicit web/native split:

- Activation paths (setKeyboardFocusHere, click-focus) call
  `showOverlayInput(box, buf[0..len.*], font_size,
  colorToU32(text), colorToU32(frame_bg_active))` instead
  of `requestSoftKeyboard(true)`.  The buffer text is
  passed through so the DOM input opens with the current
  contents pre-filled.
- Edit-ops block: `comptime` web/native dispatch.
  - **Web path**: per frame, `getOverlayInputText(buf)` →
    update `len.*` and `changed`.  Check `overlayInputIsVisible()`
    — if false, mirror `active_id = 0`.  Keep
    `cursor_pos = len.*` so any logic reading it sees
    sensible state (real cursor lives in DOM input).
  - **Native path** (host build, tests): unchanged legacy
    `chars_typed` + key_backspace/delete/arrows/Enter/Esc
    handling.
- Defocus paths (click-outside on the canvas, native
  Enter/Esc): `hideOverlayInput()` instead of
  `requestSoftKeyboard(false)`.
- Render block: when `on_web && active_id == id`,
  suppress the wasm-side text + cursor rendering.  The DOM
  overlay draws those over the canvas instead.  Background
  rect, hint placeholder, and label are still wasm-drawn
  (they render outside or behind the overlay area).

**Why this is expected to fix all the bugs:**

- **Backspace doesn't work on Android Chrome**: real DOM
  input handles `deleteContentBackward` natively.  No more
  guessing at `inputType` strings.
- **First-tap doesn't pop keyboard**: focus call is direct
  on a visible focusable element, inside the gesture
  context of the click that activated the widget (which
  goes through the wasm rAF, but the JS focus call is
  synchronous within `js_show_overlay_input` which itself
  is called from the wasm-export turn — same JS gesture
  context as the click).  iOS user-activation should be
  satisfied.
- **Scroll-into-view flakiness**: browser does its native
  "scroll focused input above the keyboard" because the
  input is a real, visible, focusable element.  Our
  `scrollFocusedWidgetIntoView` no longer runs (it stays
  in the code but is unwired from the activation paths;
  cleanup pending turn 296).
- **Keyboard blinking on non-text taps**: the pre-focus
  hack is gone; only widget activation triggers focus.

**What you'll see (visual swap):**

While editing, the user sees the DOM input's styling, not
zimr's wasm rendering.  Same font size, same colors, same
exact rect — but it'll look subtly different (OS-rendered
input vs zimr-rendered text).  On Android: native focus
ring may appear briefly; iOS: rounded corners.  We accept
this trade-off; zhobo accepts it too.  Polish is turn 294.

**Position assumption:**

`position: fixed` requires the canvas to be at viewport
(0,0).  True for zimr's current `host.html` (canvas is
`width: 100vw; height: 100vh; display: block` with body
at `margin: 0`).  If we ever support embedded
non-fullscreen canvases, the show-overlay code needs to
add the canvas's `getBoundingClientRect().left/top` to
the widget coords.  Filed as followup.

**Audit:**

- `zig build test`: 1389 / 1389 PASS.
- Standalone built ~7s focus-filtered.
- Both wasm and native targets compile cleanly.
- TS bundle: bun is happy with the new imports.

**Files touched (5):**

- `src/web.zig` — replaced soft-keyboard extern with four
  overlay-input externs + wrappers.  ~50 lines diff.
- `src/ui.zig` — `inputTextImpl` web/native dispatch in
  edit-ops + render blocks.  `requestSoftKeyboard` replaced
  by `showOverlayInput` / `hideOverlayInput` /
  `overlayInputIsVisible` / `getOverlayInputText` wrappers.
  ~140 lines diff (most of it the web-edit-ops block which
  is much shorter than the native path that it preserves).
- `src/web/zimr.ts` — new `ensureOverlayInput` factory,
  new `rgbaU32ToCss`, four new imports replacing the old
  soft-keyboard import.  Removed all hidden-input plumbing.
  ~140 lines diff.
- `src/notes/imgui-plan.md` — Step 1.8 header marked
  "🟡 PROTOTYPE turn 293".
- `src/notes/changelogs/changelog290-299.md` — this entry.

**Implementation choices:**

- **No opt-in flag.**  Always-on per Simon "maximal
  quality demands an actual dom, yes".  Desktop browsers
  also use the overlay; the visual swap is minor on
  desktop and the unified code path is worth it.  If
  desktop UX feels wrong on testing, add a Style flag
  later — but default to always-on.
- **Native path preserved.**  `inputTextImpl`'s native
  edit-ops are kept inside the `comptime else` so tests
  (which run on native host) still exercise the
  chars_typed/key_* path.  ~100 native tests for
  inputText would have broken otherwise.
- **Append to `document.body`, not canvas's parent.**
  zhobo appends to body for `position: fixed` to work
  against viewport regardless of containing block.
  Matches zhobo's choice.
- **`enterKeyHint = "done"`.**  Keeps the polish from
  turn 282.
- **No double-rendering of text.**  zhobo lets both
  imgui-side text AND DOM input render simultaneously.
  For zimr, with a custom bitmap font that won't pixel-
  match the CSS-rendered DOM text, double-rendering would
  look like ghosted text.  We suppress the wasm-side
  render while overlay is up — cleaner visually.
- **Cursor seeded to end of text.**  `setSelectionRange(n,
  n)` after focus.  Matches imgui convention.
- **TextEncoder via state.encoder.**  Uses the shared
  encoder instead of a new one per call (saves
  allocations).
- **`overlayInputIsVisible` polled each frame, not
  event-driven.**  Simpler than wiring a wasm export the
  blur listener calls — same effect, no plumbing.
  ~1 µs/frame cost, negligible.

**What's NOT done yet (future turn work):**

- **Turn 294 polish**: font/color matching refined,
  visual diff between zimr-render and DOM-render
  minimized.  Possibly font-family override per zimr's
  bitmap font name.
- **Turn 295**: confirm overlay works on iOS Safari.
  Currently only Android phone tested by Simon.
- **Turn 296+**: remove `scrollFocusedWidgetIntoView` +
  `restoreWindowScrollAfterDefocus` + `saved_scroll`
  field on `InputTextState`.  Remove the now-dead
  `requestSoftKeyboard` doc block (already done turn 293).
  Possibly remove `visualViewport` canvas-shrink if native
  scroll-into-view proves sufficient.
- **iOS/Android focus-ring polish**: try `outline: none`
  + custom focus indicator if the native outline looks
  bad.
- **Multi-line `<textarea>`**: zhobo supports this; zimr
  doesn't have multi-line text widget yet (filed in plan
  Step 1.7 followups), so wait until that lands.

**Open question to settle on phone test:**

- Does the DOM input position correctly under DPR > 1?
  Coords are in CSS pixels but `state.canvas.clientWidth *
  dpr` could mean `0.5px` offsets on some DPRs.  Expect
  minor sub-pixel misalignment; fix in turn 294 polish if
  noticed.

**Next turn:** depends on phone test.
- Works → turn 294 polish.
- Mostly works with quirks → diagnose specific quirk.
- Doesn't work → fall back to git history; the previous
  turn-291 build is preserved at zimr-turn-291.zip.

---

### Turn 292 — Studied zhobo63/imgui-ts; filed Step 1.8 (native overlay text input)

Simon: "I dont want to give up. We might need to draw our
own keyboard, but maybe we need to continue trying. Study
deeply what zhobo is doing."

Read zhobo63/imgui-ts source (the most successful imgui-web
binding for mobile).  ~120 lines in `src/input.ts` +
~50 lines of `input_text_update` in `src/imgui_impl.ts`.

**The architectural shift:**

zhobo does NOT use a hidden input forwarding chars to wasm
(the "standard hack" we've been doing).  Instead:

- **Visible** `<input type="text">` at `position: fixed`
  with `z-index: 999`, styled to match the widget (font,
  color, bg).
- Positioned EXACTLY over the imgui-drawn widget rect via
  `setRect(x, y, w, h)` each frame the widget is active.
- While focused, the DOM input IS the text editor.  Native
  browser handles: keyboard, backspace, IME, selection,
  cursor, copy/paste, scroll-into-view above the keyboard.
- Each frame, `inpState.Text = inp.Text` syncs the DOM
  input's value back into imgui's text buffer.
- On blur (Tab / click-outside / Enter on single-line),
  `setVisible(false)` hides the overlay and the imgui
  widget resumes rendering normally.

The wasm widget renders its own contents normally when
inactive; while active, the visible DOM input occludes the
imgui-rendered text with its own — the user sees a brief
visual swap on focus and blur, but content is consistent
because the buffer text and DOM value are kept in sync.

**Why this solves all our hard problems:**

- **Backspace:** real DOM input; native delete-backward.
  No need to detect `inputType: deleteContentBackward`.
- **First-tap-no-keyboard:** focus is direct on a real
  focusable element, not via a side channel.  No race
  against wasm rAF.
- **Scroll-into-view:** browser does its native "scroll the
  focused input above the keyboard."  Our
  `scrollFocusedWidgetIntoView` + canvas-shrink become
  unnecessary.
- **IME:** native.
- **Selection:** native.
- **Copy/paste:** native.

**The trade-off zhobo accepts (and we'd inherit):**

While editing, the user sees the DOM input's styling, not
the imgui widget's.  If styled carefully (same font,
colors, exact rect), the swap is subtle but not invisible.
OS-specific differences (iOS rounded corners, Android
focus ring) remain visible.

**Filed as Step 1.8 in the plan:**

Decision: keep Step 1.7 (hidden-input) shipped as the
desktop default + the mobile fallback while Step 1.8
(overlay) stabilizes.  Implementation phased across ~4
turns:

1. Turn 293 prototype: overlay alongside hidden, opt-in.
2. Turn 294: polish font/colors.
3. Turn 295: flip default for web.
4. Turn 296+: remove hidden-input path,
   `scrollFocusedWidgetIntoView`, visualViewport shrink.

Net code change estimate: +170 lines new, -260 lines old
when cleanup completes.  Smaller codebase, more capability.

**No code this turn.**  Plan first, code second.  The
study of zhobo's reference was the deliverable.

**Audit:**

- `zig build test`: 1389 / 1389 PASS (no code changes).

**Files touched (2):**

- `src/notes/imgui-plan.md` — added Step 1.8 with the
  architecture summary, why-this-works analysis,
  desktop-coexistence plan, and 4-turn implementation
  order.
- `src/notes/changelogs/changelog290-299.md` — this entry.

**Implementation choices (deferred to turn 293):**

The overlay path's main design decisions to settle when
prototyping:

- **`position: fixed` vs `position: absolute`.**  zhobo
  uses fixed.  Works because the canvas is at viewport
  (0,0) in his demo (and ours).  If we ever support
  embedded canvases (non-fullscreen), this needs revisiting.
- **Font matching.**  zimr uses a custom bitmap font; DOM
  inputs use a CSS font.  Exact pixel-match impossible;
  aim for "monospace, same size, same color" close-enough.
- **When to poll the input value.**  zhobo polls in the
  per-frame `input_text_update`.  Same approach for zimr:
  inside `inputTextImpl`, if `ctx.active_id == id`, call
  the new `js_overlay_input_get_text` extern.
- **Suppress wasm-side text rendering when active?**  zhobo
  does NOT — both render simultaneously, the DOM input
  overlays the imgui-drawn text.  For zimr, given the
  visual swap is unavoidable, we may want to suppress the
  wasm rendering so there's no double-render flicker.
  Decide after seeing the prototype.

**Next turn (293):** Prototype Step 1.8 phase 1 — overlay
alongside hidden-input, opt-in via a demo flag, prove
the architecture works on Simon's Android phone.

---

### Turn 291 — Close the keyboard arc: prior art + remove pre-focus + file the rest as known issues

Simon (three screenshots): scroll-into-view doesn't work
reliably, never shows DBG output, "When i press the add
button i see a keyboard blinking."  Then: "Now might be the
time to really look for what imgui and emscripten do for this
problem? Maybe nothing and they have the same problem?"

Then after research: "Lets forget about first tap problem for
now."

**Prior-art research:**

Web-searched imgui + emscripten + mobile keyboard.  Findings
sobering and useful:

- imgui issue #5133 (March 2022, never resolved): imgui +
  sokol + emscripten on Android Firefox — "Normal keys like
  letters and numbers work.  Backspace does not work and nor
  does enter/return."  This is EXACTLY the bug Simon
  reported about backspace this turn.
- emscripten-discuss thread (Floh, sokol author, June 2020):
  "I explored a 'solution' which involves a hidden HTML text
  field, focusing that text field to bring up the keyboard,
  and unfocusing it to hide the keyboard again.  It kinda
  works, but it has all sorts of problems...  don't expect
  it to work for more than six months after a browser update
  breaks something."  Eventually drew their own keyboard.
- emscripten-ports/SDL2 issue #80: still open in 2022; no
  clean virtual-keyboard support exists.
- zhobo63/imgui-ts (most successful imgui-web for mobile):
  uses VISIBLE overlay `<input>` / `<textarea>` positioned
  on top of the widget.  User sees the native input
  directly; the imgui-rendered widget becomes decorative.
  Different UX trade-off.
- Floh's June 2020 testing note: "No issues with triggering
  the focus/keyboard programmatically, e.g. from a setTimeout
  (iOS-specific issue?)" — i.e. **Android allows non-gesture
  focus().  iOS does not.**

Conclusion: zimr's hidden-input approach matches the
community's standard hack.  The known limitations of the
standard hack apply.  No clean fix exists in the ecosystem;
this is the territory.

**Action this turn — simplify:**

Removed the touchstart pre-focus + 60ms blur timer from turn
285.  Reasons:

1. **Caused visible keyboard flash on every non-text tap.**
   Simon turn 291: "When i press the add button i see a
   keyboard blinking."  Pre-focus pops the keyboard; 60ms
   later the timer dismisses it.  Annoying on Add, Clear,
   Top, etc.

2. **Raced wasm's rAF tick.**  Under load or on slow
   devices, wasm's rAF could be delayed past 60ms.  Blur
   fires BEFORE inputTextImpl calls requestSoftKeyboard(true).
   Keyboard dismisses.  Next focus call (now outside the
   gesture window) is refused on Android.  PLAUSIBLY the
   first-tap-no-keyboard bug we'd been chasing.

3. **Net negative for Android.**  Floh's findings confirm
   Android allows non-gesture focus().  The pre-focus only
   helps iOS — and now blocks Simon's primary platform.

Files changed in `src/web/zimr.ts`:
- Touchstart handler: removed the ensureSoftKeyboardInput +
  focus + setTimeout(blur) block.
- RuntimeState: removed `softKeyboardPendingDrop` field.
- `js_request_soft_keyboard`: removed the cancel-pending-drop
  line.
- Kept the explanatory comment block about WHY this isn't
  there anymore, since the temptation to re-add it is
  predictable.

iOS first-tap-no-keyboard is now a deferred known limitation
(filed in Step 1.7's followups list with three concrete
fix-attempt candidates).

**Diagnostic instrumentation removed:**

Earlier in turn 291 (before this realization), reverted the
turn 288-289 diagnostic capture in log_viewer:
- Removed `appendDiag` helper.
- Removed `dbg_*` capture variables around filter draw.
- Removed `dbg_*` State fields.
- Restored 80-line seed, auto-emission, SPACE shortcut.

log_viewer is back to its turn-281 state plus all the
between-state fixes.

**Step 1.7 plan update:**

Folded prior-art findings into Step 1.7's followups section.
Filed three known limitations explicitly:
- First-tap-doesn't-pop-keyboard (iOS).
- Backspace doesn't delete (Android Chrome IME sends
  `inputType: deleteContentBackward` via `input` event,
  not a `keydown`).  Future fix: listen for `beforeinput`
  with that inputType.
- Soft-keyboard scroll positioning flaky for empty-window
  case (scroll_max_y = 0 makes scroll a no-op).

Plus the still-open visual-smoke-test followup that would
have caught all this earlier.

**What's KEPT from turns 282-287:**

- `requestSoftKeyboard` extern in `src/ui.zig`.
- `ensureSoftKeyboardInput` factory in `src/web/zimr.ts`
  (still called from `js_request_soft_keyboard` lazy init).
- Hidden `<input type="text">` with `enterKeyHint = "done"`.
- `input` event → forward chars to wasm.
- `keydown` listener for Enter (Done) → immediate blur +
  preventDefault.  Confirmed working by Simon turn 284.
- `visualViewport` listener → shrink canvas on keyboard pop,
  restore on dismiss.  Working.
- `scrollFocusedWidgetIntoView` + `restoreWindowScrollAfterDefocus`
  in ui.zig.  Works for populated-log case; no-op for
  empty-window case.

The keyboard arc closes here.  Step 1.7 stays marked DONE
turns 282/283 in the plan (the additional fix turns are part
of the same arc's shipping cost).

**Audit:**

- `zig build test`: 1389 / 1389 PASS.
- Standalone built focus-filtered.

**Files touched (3 this turn, net of the diag revert):**

- `src/web/zimr.ts` — removed pre-focus block,
  `softKeyboardPendingDrop` field, the cancel line.  Net:
  about 70 fewer lines than turn 290.
- `examples/ui_log_viewer.zig` — reverted to pre-diagnostic
  state (seed + auto-emit restored, appendDiag removed).
- `src/notes/imgui-plan.md` — Step 1.7 followups
  consolidated with prior-art context.
- `src/notes/changelogs/changelog290-299.md` — this entry.

**Next turn:** Step 1.3 — MultiSelect + SelectionBasicStorage.
The keyboard arc is DONE (with known limitations filed).
Resume normal plan order.

---

### Turn 290 — Widened diagnostic emit + diagnostic State fields + realization

Simon's screenshot showed: filter typed `dgyhhjgdh jvf`, lines=0,
shown=0, NO DBG lines, screen never scrolled.

**Two realizations:**

**Realization 1: the diagnostic was too narrow.**  Turn 288's
emit condition was `filter_caused_scroll = @abs(after_filter -
before) > 0.5`.  This fires ONLY when zimr actually moved
`w.scroll_y`.  If `scrollFocusedWidgetIntoView` ran but the
clamp wedged `scroll_y` at its current value (e.g. because
`scroll_max_y = 0`), `after_filter == before`, no DBG line.

Widened emit to fire on ANY of: filter-caused scroll, between-
frame scroll drift, autoscroll-actually-moved, or buf_len
changed.  Added State fields:

- `dbg_frame: u32` — counter, included in each DBG line.
- `dbg_last_scroll_end: f32` — end-of-prev-frame scroll, for
  between-frame drift detection.
- `dbg_last_buf_len: usize` — for buf_len-changed trigger
  (typing emits DBG so we know SOMETHING is happening even
  without scroll).

New format: `f{frame} dy {before}>{flt}>{lines}>{end} mx={n}
as={bool} bl={n}`.

**Realization 2 (the bigger one): scroll-into-view CANNOT help
when content fits in the viewport.**

`scrollFocusedWidgetIntoView` writes `w.scroll_y =
clamp(old + delta, 0, scroll_max_y)`.  If `scroll_max_y == 0`
(content fits in window), clamp pins scroll_y at 0
regardless of delta.  No scroll occurs.

With turn 289's auto-emission disabled for diagnostic mode,
the log has zero lines.  Window content is small.
`scroll_max_y = 0`.  The widget renders at its natural
layout position — somewhere in the lower portion of the
window if the window is taller than the content above the
filter.  Scroll-into-view does nothing useful because there's
literally no scrollable axis.

**The bug I've been chasing for 8 turns might actually be a
DIFFERENT bug than I thought.**  When the log has many lines
and the user has scrolled down, scroll-into-view works
(maybe flakily).  When the log has few lines, scroll-into-
view is structurally a no-op and the widget stays put — under
the keyboard if positioned that way.

For the "content fits" case, the fix has to MOVE THE WINDOW
itself (`w.pos[1]`), not scroll its content.  That's a much
bigger surgery — ui.zig generally treats window positions as
user-owned.

**Action plan:**

1. Ship the widened diagnostic so Simon can confirm what's
   happening: is `scrollFocusedWidgetIntoView` running and
   doing nothing, or not running at all?
2. After Simon's next screenshot, decide between:
   - Move-the-window fix (drastic, breaks window-position
     ownership semantics).
   - Canvas-shrink already in turn 283/284 should handle the
     short-content case — verify if it's actually firing.
   - Accept that for short content the widget is sometimes
     under the keyboard; pin a workaround for log_viewer
     specifically (e.g. ensure window content always exceeds
     viewport).

**Other housekeeping:**

- Decade rollover: turn 290 starts `changelog290-299.md`,
  freezes `changelog280-289.md`'s [Unreleased] header.
- Cleanup of the appendDiag / dbg_* instrumentation still
  pending — stays until the actual bug is understood.

**Audit:**

- `zig build test`: 1389 / 1389 PASS.

**Files touched (3):**

- `examples/ui_log_viewer.zig` —
  - Added `dbg_frame`, `dbg_last_scroll_end`, `dbg_last_buf_len`
    fields to State.
  - Widened DBG emit conditions (4 OR'd triggers).
  - New DBG format includes frame counter and buf_len.
- `src/notes/changelogs/changelog280-289.md` — frozen header.
- `src/notes/changelogs/changelog290-299.md` — created, this entry.

**Implementation choices:**

- **Emit-on-typing is the key new trigger.**  Even when
  scroll never moves, the user typing in the field is a
  signal that "focus is active right now."  Confirms or
  refutes "did focus activation happen at all" without
  needing scroll to also have moved.
- **Frame counter in the DBG line.**  Helps read time order
  in a screenshot where multiple DBG lines appear close
  together.
- **No fix attempted this turn.**  My turn-287 reasoning was
  wrong (canvas_h race wasn't the only issue) and my
  turn-289 disabling auto-emission broke the very scenario
  the bug appeared in.  Need actual data before another fix
  attempt.

**Test procedure for Simon's next phone session:**

1. Open the new standalone.
2. Tap Add 100 a few times to populate logs (so window has
   scrollable content — `scroll_max_y > 0`).
3. Scroll down in the log a bit (so filter is OFF the top of
   the visible viewport).
4. Tap the filter input.  Type something.  Tap Done.
5. Screenshot.

Expected DBG lines should appear when the filter is tapped
and when typing happens.  Numbers will tell whether
`scrollFocusedWidgetIntoView` is running and what scroll-y
values it sees.

**Next turn:** decode the next screenshot.  Based on what
DBG shows:

- If DBG lines appear AND scroll changed → original
  hypothesis (auto-scroll race) → test the fix.
- If DBG lines appear AND scroll didn't change → look at why
  (scroll_max_y was 0?  delta was sub-pixel?  etc.).
- If NO DBG lines → activation is bypassing inputTextImpl
  somehow.  Deep investigation needed.
