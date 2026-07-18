# System audit + finishing plan — turn 412

Written after shipping P8.4 (table sizing modes).  Surveys the whole
zimr codebase, identifies what's working / what's debt / what's
latent, and proposes a path through the remaining imgui plan
interleaved with system-improvement work.

This document is intended to be **the single index for "what's
next."**  When Simon asks "what should we do?", the order in §5
is the answer.

---

## 1. System snapshot — turn 412

| Metric | Value |
|---|---|
| `src/ui.zig` lines | 31 793 |
| tests in `src/ui.zig` | 443 |
| total test files | 27 |
| `examples/*.zig` | 116 |
| `pub fn` exposed on `Ui` | 278 |
| `src/notes/*.md` | 30+ planning + tutorial docs |
| Live lint rules | 10 `warnOnce` sites in ui.zig |
| `TODO`/`FIXME` markers in ui.zig | 24 |
| Imgui parity audit | `zimr-vs-imgui-divergence-audit.md`, 565 lines |
| Imgui plan | `imgui-plan-v7.md`, 1 008 lines |

zimr is a substantial codebase by any measure — about half the line
count of imgui's `imgui.cpp` + `imgui_widgets.cpp` combined, with
broadly similar feature coverage.  The "imgui completion plan" is
roughly 60% done by phase count and probably 70-80% by widget surface.

---

## 2. What's working well

These are intentional design choices that should NOT be revisited
or "refactored away":

- **`AppBridge` pattern** (vs imgui's `GImGui` global).  Per-app
  context owned by user `main`.  Multi-app coexistence works
  (`src/tests/multiapp_test.zig`).  Hot-reload-safe.  See
  audit §5.
- **Deferred draw lists + splitter**.  `DrawList` cmds + `splitter`
  give correct z-order without index manipulation.  Table P7.2
  was the proof point.
- **Per-frame style application via `u.style()`**.  Mutate the
  pointer at the top of `update`; zero boilerplate.  No `PushStyleVar`
  /`PopStyleVar` stack.
- **Lint asserts** (`warnOnce` + 10 active rules).  Each one was
  written in response to a real bug class.
- **Persistence via `.zon`** (`src/ui_persistence.zig`).  Window
  positions + styles + sort specs survive across runs.
- **Hard lint gate** (`zig build lint-check`).  CI fails on any
  rule hit.  Self-enforcing API hygiene.
- **Memory model**.  `frame_arena` for per-frame allocations
  resets cleanly each frame; `gpa` for persistent state with
  matched `deinit` for every hashmap.  Zero leaks across the
  test suite.

The "consult imgui source" rule shipped in turn 411 is now also
working well — turn 412's P8.4 went through `imgui.h` and
`imgui_tables.cpp` BEFORE any zig was written, and the result was
visibly cleaner than the prior P8 turns.

---

## 3. Audit findings

Organized by area.  Each item has a **severity** tag:

- 🟥 **blocker** — actively wrong; user-visible bug
- 🟧 **major** — significant quality issue; should fix soon
- 🟨 **minor** — papercut or known limitation; fix when adjacent
- 🟦 **architectural** — design-level; needs Simon-level decision

### 3.1 Code organization

#### 🟧 `src/ui.zig` is too big (31 793 lines)

The whole UI module lives in one file.  Section markers
(`// ====...====`) divide it into ~25 sub-areas, but cross-references
are dense and editing requires line-number scrolling.  Effects:

- Compile times nontrivial (full rebuild ≈ 5 s, incremental ≈ 0.7 s)
- `view`-based tool workflow has to use range slicing constantly
- Single-file means one error breaks everything

**Recommendation**: split into `src/ui/` directory after the imgui
arc closes (deferred so plan turns don't have to navigate moved
code).  Suggested split, by section marker boundary:

```
src/ui/
  core.zig          ← UiContext, Style, ItemFlags, Window
  draw_list.zig     ← DrawList, DrawListSplitter (lines 811-2200)
  hashing.zig       ← Id, hashStr, widgetId
  widgets/
    button.zig
    text.zig
    input.zig
    tab_bar.zig     ← the turn-411 work
    table.zig       ← the P8 work
    tree.zig
    selectable.zig
    drag_drop.zig
    multiselect.zig
  layout.zig        ← cursor, sameLine, separator
  popup.zig
  dock.zig          ← already partially split into ui_dock.zig
  persistence.zig   ← already separate file
  metrics.zig       ← P2.2 frame metrics
  tests/            ← move 443 inline tests out, keep alongside
  ui.zig            ← thin top-level re-exports
```

Effort: **2-3 turns** of mechanical work plus careful test runs.
Lint will catch most regressions.

#### 🟨 Plan/notes directory accumulating

30+ `.md` files in `src/notes/`.  Some are now-stale (old plans,
archived investigations).  Hard to know which are current.

**Recommendation**: move stale docs to `src/notes/archive/` with
a one-line redirect (e.g. "see X-plan.md").  Live docs at top
level: `claude.md`, `CHEATSHEET.md`, `imgui-plan-v7.md`,
`zimr-vs-imgui-divergence-audit.md`, `system-audit-and-finishing-plan-turn-412.md`
(this one).  Maybe `getting-started.md`, `architecture.md`.

Effort: **1 turn**.

### 3.2 imgui parity

#### Remaining phases (from `imgui-plan-v7.md`)

| Phase | Scope | Effort estimate |
|---|---|---|
| **P8.5** scroll flags | `scroll_x` flag, explicit axis selection | 1 turn |
| **P8.6** `TableColumnFlags` wave | ~18 flags (no_resize, no_reorder, no_hide, indent_disable, etc.) | 2 turns |
| **P8.7** angled headers | Diagonal column header text | 2 turns |
| **P8.8** table queries | `getColumnIndex`, `getColumnCount`, `getColumnName` | 1 turn |
| **P9** InputText flag wave | Char filters + behavior flags + callbacks | 3 turns |
| **P10** ColorEdit flag wave + converters | Picker variants + alpha/HDR + RGB↔HSV | 3 turns |
| **P11** Selectable callback redesign | Scoped down from v6 | 1 turn |
| **P12** Drag/Slider drag2/3/4 | Range-in-opts audit + DragN/SliderN | 2 turns |
| **P13** MultiSelect completeness | Nested scopes + shift-click range | 2 turns |
| **P14** Logging family | TextWrapped + BulletText + LabelText | 2 turns |
| **P15** show* family closeout | showDemoWindow, showAboutWindow | 1 turn |
| **P16** Outliers + checkboxFlags | KeyboardKey expansion + popup variants + flag checkboxes | 2 turns |
| **P17** Compile-time validation | Format-string validation, range checks | 2 turns |
| **P18** Capstone polish + archive | Showcase polish, perf pass, archive | 3 turns |

**Total**: ~27 turns of imgui-plan work, OR could be compressed
to ~20 turns if some smaller phases are batched.

#### 🟧 Pending decisions from divergence audit (turn 411)

These need Simon-level calls before they can be implemented:

1. **`style.alpha` global multiplier** (divergence audit §4.1).
   imgui has it; zimr has `alpha_mul` on `UiContext` (per-scope
   `beginDisabled` only).  Decision: add `style.alpha` to match,
   or leave it as a feature gap?
2. **Table padding L+R semantics** (audit §2.5).  imgui pads both
   sides; zimr pads only left.  Decision: switch to symmetric, or
   keep the simpler one-sided model?
3. **Color name `tab_active` vs `TabSelected`** (audit §4.2).
   imgui renamed it; zimr kept the old name.  Decision: rename
   to match (breaking change) or keep?
4. **Tab section-order sort** (audit §1.7).  imgui has it (lead/
   tail/center sections); zimr doesn't.  Decision: implement, or
   document as out-of-scope?

Estimated effort if all four green-lit: **2-3 turns**.

#### 🟦 Architectural deferrals

These would be sizeable refactors and are NOT recommended for the
arc; flagging them so the decision is explicit:

- **Deferred tab-bar render** (audit §1.2).  Fixes the 1-frame
  `is_active`-after-click latency by deferring all tab rendering
  to `endTabBar`.  Requires inverting the tab-bar API from
  inline-submission to record-and-replay.  Estimated 3-4 turns.
  Current 1-frame visual lag is barely perceptible at 60fps —
  not worth the refactor.
- **Multi-row tab bars** (imgui has them).  Out of scope.
- **Docking ImGui-style** — zimr's docking (`src/ui_dock.zig`)
  predates this plan and works.  Not worth re-architecting.

### 3.3 Latent bugs

#### 🟥 Table row-height measurement misses last cell of each row

Discovered while implementing P8.4.  `tableNextColumnImpl` snapshots
the previous column's height into `row_max_h` when ADVANCING within
a row.  But the LAST cell of each row never has a "next column"
call after it, so its height is never captured.

**Symptom**: a row whose tallest cell is the rightmost column gets
clipped — visible content sticks out below the row's drawn bg.

**Fix**: replicate P8.4's snapshot-at-three-sites pattern for height
too.  Add a height-snapshot call to:
- `tableNextRowImpl` (else branch, before computing `row_bottom`)
- `endTableImpl` (before computing `last_row_bottom`)

Same code shape as `snapshotCellWidth`.  Effort: **0.5 turn**.

#### 🟨 Tab 1-frame `is_active` lag (divergence audit §1.2)

Documented; deferred (see 3.2 above).

#### 🟨 Cell-bg clip-rect optimization (audit §2.4)

When a table has many cell-bg overrides, each goes through the full
draw-list path even when fully clipped.  Perf only; correctness OK.
Effort: 1 turn.

#### 🟨 Color picker auto-disable in `beginDisabled` scope

Not in the audit but spotted during this audit.  `colorEdit` doesn't
re-check `alpha_mul` per-pixel — it dims the swatch chrome but the
picker popup contents may not respect disabled state consistently.
Worth a small test pass during P10.

### 3.4 Test coverage

#### What's well-tested

- Tab bar: 5 new tests in turn 411 cover the priority + lift
- Table layout: P8.4's 9 new tests cover the four modes
- Cell bg / row bg: P8.1 added thorough coverage
- Hashing / id collisions: solid
- Persistence round-trip: solid

#### Coverage gaps

- 🟨 **Multi-window scenarios**.  Each window in isolation is
  well-tested, but interactions (modal popups over windows, drag-
  drop across windows, focus chain across windows) get less
  coverage.  Risk: regressions land silently in cross-window
  flows.
- 🟨 **Resize/reflow under live input**.  Tests typically use
  static window sizes.  A whole class of "layout cursor jumps when
  parent resizes mid-frame" bugs would slip through.
- 🟨 **Persistence edge cases**.  Tests cover happy-path save/load
  but not corrupted-zon recovery, version-mismatch, missing-tab
  references after a window's tab list changes.
- 🟨 **Performance regressions**.  No perf-test harness.  A
  10× slowdown in `computeTableColumnLayout` would pass all 1685
  tests.

**Recommendation**: add a `tests/perf/` directory with timer-
based regression tests that fail if wall-clock for a known
scenario exceeds a threshold.  Effort: **1 turn** for scaffolding,
ongoing per-feature.

### 3.5 Performance

#### What's known

- `frame_arena` reset is cheap (single-call arena clear)
- DrawList allocation goes through `frame_arena`; no per-frame GC
- Lint rules sample frame metrics into `ctx.frame_metrics`

#### Untested

- Cost of `computeTableColumnLayout` with N=32 columns × frame
- Cost of the per-cell `snapshotCellWidth` call added in P8.4
  (theoretically O(1) per cell, but never measured)
- `splitter.merge` cost when both channels have thousands of cmds
  (e.g. 1000-row scrolling table — visible-only or full?)

**Recommendation**: when P18.2 (the "performance pass" marker) is
reached, do a real measurement with `examples/ui_full_showcase.zig`
at 60fps.  Profile, fix the worst offender, repeat.  Don't do
this before P14 — too many features still being added.

### 3.6 Documentation

#### Good

- `CHEATSHEET.md` is comprehensive
- Doc comments on `pub` API are nearly universal
- Changelog entries (`changelog360-369.md`) are detailed and useful
  for reconstruction of intent

#### Gaps

- 🟨 Architecture overview is scattered across
  `architecture.md`, `architecture-imgui-vs-zimr.md`,
  `architecture-tutorial.md` — hard for newcomers to know where
  to start
- 🟨 The new `zimr-vs-imgui-divergence-audit.md` (turn 411) is
  excellent but very recent; adoption pending
- 🟨 No "how to add a new widget" tutorial — implicit knowledge
  in the existing code, not written down

**Recommendation**: as part of P18.3 (plan archive + cheatsheet
regen), consolidate the architecture docs into one
`ARCHITECTURE.md` and write a "adding a new widget" tutorial.
Effort: **1 turn**.

### 3.7 Tooling & workflow

#### Good

- `claude.md` rules work — they catch shape-of-error things early
- Lint is fast (0.24 s)
- Save-zip-and-prune pattern keeps the output dir tidy
- The transcript-compaction-with-summary pattern survives long
  multi-turn arcs

#### Gaps

- 🟨 No automated way to verify imgui-source citations in changelogs
  (the rule from turn 411).  Could grep for "imgui_widgets.cpp:" /
  "imgui.h:" tokens in entries since the rule was added.
- 🟨 Standalone build (`build_standalone.py`) is slow (~2 min).
  Not blocking but worth investigating.

---

## 4. Pending decisions block

Before charging through the remaining plan, get Simon's call on the
audit's "Pending decision" items:

1. **`style.alpha` global** — add for imgui parity, or leave the
   per-scope `alpha_mul` model alone?
2. **Table L+R padding** — switch to symmetric padding, or keep
   one-sided?
3. **`tab_active` → `TabSelected` rename** — adopt imgui's name,
   or keep zimr's?
4. **Tab section-order sort** — implement (lead/center/tail), or
   document as out-of-scope?

If all four are deferred, the imgui arc still closes — these are
quality-of-parity items, not features.

---

## 5. Prioritized finishing plan

The plan below interleaves remaining imgui phases with
system-improvement work so quality and feature surface advance
together.  Each item lists turns; total ≈ 32 turns to arc close.

### Tier 1 — Latent-bug fixes + quick wins (next 2-3 turns)

These are small, high-value, and unblock everything else:

- **T1.1 Fix table row-height last-cell measurement** (latent
  bug 3.3 above).  Mirror P8.4's snapshot-at-three-sites pattern
  to height.  0.5 turn.
- **T1.2 P8.5 scroll flags** (`scroll_x`, explicit axis).  1 turn.
- **T1.3 P8.6 `TableColumnFlags` wave** (~18 flags).  2 turns.

Outcome: tables substantially complete.

### Tier 2 — Resolve pending decisions (1-2 turns)

If Simon greenlights the §4 items, knock them out together:

- **T2.1 `style.alpha` global** (if approved).  0.5 turn.
- **T2.2 Table padding L+R** (if approved).  Breaking change for
  one or two test fixtures.  0.5 turn.
- **T2.3 `tab_active` → `TabSelected` rename** (if approved).
  Mechanical refactor.  0.5 turn.
- **T2.4 Tab section sort** (if approved).  1 turn.

If all deferred, skip Tier 2 and go straight to T3.

### Tier 3 — Complete the imgui widget surface (≈ 13-15 turns)

Run through the remaining phases in plan order.  Each one follows
the new turn-411 rule: read imgui source first, cite file:line in
the changelog.

- **T3.1 P8.7 angled headers** — 2 turns
- **T3.2 P8.8 table queries** — 1 turn
- **T3.3 P9 InputText flag wave** — 3 turns (largest single batch)
- **T3.4 P10 ColorEdit + converters** — 3 turns
- **T3.5 P11 Selectable callback** — 1 turn
- **T3.6 P12 Drag/Slider N-variants** — 2 turns
- **T3.7 P13 MultiSelect completeness** — 2 turns

Outcome: feature parity with imgui's commonly-used surface.

### Tier 4 — Closeout + polish (≈ 8-10 turns)

- **T4.1 P14 Logging family** — 2 turns
- **T4.2 P15 show* family** — 1 turn
- **T4.3 P16 Outliers + checkboxFlags** — 2 turns
- **T4.4 P17 Compile-time validation** — 2 turns
- **T4.5 P18.1 Showcase polish** — 1 turn
- **T4.6 Multi-window test coverage** (audit 3.4) — 1 turn
- **T4.7 Perf-test harness** (audit 3.4) — 1 turn

### Tier 5 — System improvements (≈ 4-5 turns)

These happen AFTER the imgui arc closes — they touch a lot of code
and would be risky in parallel with plan work:

- **T5.1 Architecture doc consolidation** — 1 turn
- **T5.2 `src/notes/` archive cleanup** — 1 turn
- **T5.3 Split `src/ui.zig` into `src/ui/` directory** — 2-3 turns
  (mechanical; lint catches regressions)
- **T5.4 P18.2 Performance pass** — open-ended, ≥ 1 turn

### Tier 6 — Arc close

- **T6.1 P18.3 Plan archive + cheatsheet regen** — 1 turn
- **T6.2 P18.4 Arc-close changelog entry** — 1 turn

---

## 6. Risk register

What could break the plan:

- 🟧 **Scope creep on P9 InputText** — character filters + behavior
  flags + callbacks is a wide surface.  If it grows to 5 turns,
  it eats Tier 3 momentum.  Mitigate: split into 3 smaller PRs
  and ship each.
- 🟧 **`src/ui.zig` split fights with active plan work** — if T5.3
  starts before T4 finishes, every phase has to navigate moved
  files.  Mitigate: hard rule that T5.3 is last.
- 🟨 **Latent bug discovery** — every audit pass finds more.  The
  row-height bug above was discovered this turn.  Mitigate: triage
  as found; fix immediately if blocker, file for tier 1 otherwise.

---

## 7. What this document is NOT

- It's not a re-plan of `imgui-plan-v7.md`.  That document remains
  the source of truth for each P-phase's scope.
- It's not a deprecation of `zimr-vs-imgui-divergence-audit.md`.
  That document remains the source of truth for per-feature
  imgui-zimr divergences.
- This is the **execution order** layered on top of those two.

---

## Update cadence

Update this doc at the end of each tier (T1, T2, T3, ...).  When
the imgui arc closes (T6), this doc is archived under
`src/notes/archive/`.
