# Tier 1 architectural-pillars review

**Scope**: Turns 415–430 (the architectural-pillars arc plus
snapshot-regression infrastructure).  This document records what
landed, where it differed from the original sketch, what surprised
us along the way, and whether Tier 2 is unblocked.

## Pillar status

| Pillar | Description                                  | Status |
|--------|----------------------------------------------|:------:|
| Q1     | Dense per-frame key-state array + KeyCode    | ✅     |
| Q2     | Typed-generic ext-state storage              | ✅     |
| Q3     | Widget primitives (B-path + C-path)          | ✅     |
| Q4     | Canvas widget with transform stack           | ✅     |
| Q5     | Style override guard (defer-RAII)            | ✅     |
| Q6     | Implot lifecycle                             | ⏳ Tier 4 |
| Q7     | Drawing primitives (arcs + polygon)          | ✅     |
| Q8     | Persistence integration (opt-in flag)        | ✅     |
| Q9     | Animation primitives (tween + spring)        | ✅     |

Eight of nine pillars shipped over 14 turns (415, 416, 417, 418,
419, 420, 421, 422 (a/b/c), 423, 424, 425, 426, 427, 428, 429,
430).  Q6 is intentionally deferred to Tier 4 — implot needs Q4
canvas + Q7 arcs + Q2 state, all of which exist now.

## Deltas: what shipped vs what was sketched

**Q2 — getOrPutState API shape**.  Sketched as
`getState(T, id) ?*T` + `putState(T, id, initial, opts) *T`.
Shipped that way through turn 417, then turn 423 surfaced a real
bug: the documented `getState orelse putState` idiom blasted
loaded values when `apply` ran after `putState`.  Replaced with
`getOrPutState(T, id, opts) -> { value_ptr, found_existing }`
mirroring `std.HashMap.getOrPut`.  Single hash on each map level,
caller decides whether to seed.  No two-call dance, no init-
blasts-load.  30+ callsites migrated, all tests still pass.

**Q4 — `applyPoint` renamed to `applyLocal`**.  Sketched as
`CanvasTransform.applyPoint(p) Vec2`.  Phone testing surfaced
that the name implied "transform this point to screen" but the
return value was canvas-local.  Renamed in the API-cleanup pass
(turn 424).  `toScreen(p)` is now the single sanctioned
authoring→screen helper.

**Q4 — `DrawListHandle` exposure**.  Original surface was ~8
methods.  Real callers (the node-editor example) needed
`addBezierCubic`, `addArc`, `addArcFilled`, `addPolygon`,
`addNgon`, `addNgonFilled`, `addEllipse`, `addEllipseFilled`,
`addPolyline`, `addQuadFilled`.  All forwarded through the
handle in turn 424.

**Q3 — widget migration**.  Sketched as "the primitives exist,
built-ins reimplement them inline."  Turn 426 did the migration
for button, smallButton, arrowButton, checkbox, radio, and
selectable.  Side effect: radio and selectable picked up
keyboard-nav activation parity with button/checkbox — a
pre-existing inconsistency surfaced and was fixed for free.

**Q3 — typed-state migration explicitly rejected**.  Plan
mentioned migrating `tab_bar_state`, `combo_state`,
`table_sort_state`, `table_scroll_state`,
`table_width_auto_cache` from typed bespoke fields to
`ext_storage`.  Evaluated and **rejected** — see §13.  The
typed end-to-end accessors are honest about their value types;
moving them through `getOrPutState` adds a comptime-key +
void-pointer cast layer with no functional gain.  If one of
them later wants persistence, migrate just that one.

**Q8 — `MiniPlotSlot` smoke validation**.  Fresh-eyes insertion
(turn 429) — a throwaway `u.miniPlot(label, rect, xs, ys)` that
exercises canvas + arcs + state + style + input + animation in
one call.  No composition surprises surfaced: the pillars
compose without friction.  Smoke test confirmed what unit tests
implied, but in fewer LOC and with the integration paths
actually exercised.

## Inter-pillar surprises

**`getOrPutState` is the universal slot allocator**.  Originally
designed for Q2 ("extension widget state").  Now used by Q9 for
animation slots (`TweenSlot`, `SpringSlot`) and by the Q8 smoke
test for plot state (`MiniPlotSlot`).  The `.persist = true`
flag gives any of these persistence for free.  The pattern
generalized cleanly because it's just "typed-erased map keyed by
comptime T."

**Q5 + Q9 nest cleanly**.  The miniPlot smoke calls `spring`
inside a `styleOverride` scope.  The defer-RAII style guard
restores correctly even though the animation primitive runs an
ext-state lookup inside its body.  No state collisions, no
ordering issues.  This was the design intent of defer-based
guards: callsite locality.

**Q7 `addArc` performance is fine**.  Backlog originally
flagged "if arc spam shows up in a profile, add a native arc
DrawCmd variant."  Two real consumers exist (miniPlot's
indicator dot, the animation gallery's spring track ornament).
No profile pressure surfaced.  Backlog item stays parked.

**Q1 keyboard activation parity**.  When migrating radio +
selectable to Q3 primitives (turn 426), they GAINED keyboard
activation (`triggerNavActivate`) for free because `buttonBehavior`
already calls it.  Two pre-existing inconsistencies fixed by
the migration, neither of which was on anyone's TODO.

**Q4 canvas hover guard**.  Sketched as "pointInRect on the
canvas's screen rect."  Phone testing surfaced that this fires
true even when a popup is overlaid on the canvas — visual
hover differs from semantic hover.  Added `hovered_window_id`
check in turn 422c: hover requires pointInRect AND the canvas's
parent window is the topmost at the cursor.

## Tier 2 readiness

Tier 2 phases that depend on Tier 1 pillars:

- **P9 (InputText polish)** — depends on Q1 (key-state array).
  All keyboard-driven widgets now read through `u.isKeyDown`,
  `u.isKeyPressed`, `u.isKeyPressedOrRepeat`.  P9 can lean on
  Q1 fully.
- **P8.5 (scroll flags finish)** — depends on Q1
  (`u.isShiftDown` for shift-wheel) and Q4 (clip-rect generalization).
  Both available.
- **P10 (color picker polish)** — depends on Q7 (arcs for hue
  wheel) and Q5 (style override for picker preview).  Both
  available.
- **P11 (table sorting + virtualization)** — depends on Q2
  (sort-state caching keyed by table id).  Available.
- **Tier 4 (implot)** — depends on Q4, Q5, Q7, Q2, Q9.  All
  available.  Q6 (lifecycle) is the missing piece, scheduled
  for turn 471+.

Conclusion: Tier 2 is fully unblocked.  Every prerequisite has
shipped or has an explicit "won't ship until X" entry in §13.

## Test budget

| Tier | Turns | Tests added | Cumulative |
|------|-------|-------------|------------|
| 1    | 415–430 | +~89 (1713 → 1802) | 1 802 |

Plan target was "~2 200 tests by close of arc (turn 511)".  At
1 802 by turn 430, we're 9 tests/turn ahead of trajectory for
the 81 remaining turns.  No risk to the test budget.

## What's NOT in this review

- Turn-by-turn microscope.  See the changelog (`src/notes/
  changelogs/changelog360-369.md`) for that level of detail.
- LOC budgets per pillar.  Track on next checkpoint review.
- A Carmack sweep wishlist.  The actual sweep happened
  organically (turns 422–429 absorbed ~6 small inlines as we
  migrated callers); not worth a separate audit.

## Next checkpoint

Tier 2 review at turn 463 per plan §15.  Carry forward: were any
Tier 1 deltas exposed as bugs by Tier 2 consumers?
