# The big plan — turns 415-511: imgui parity finish + implot port (plus cleanups)

Supersedes `refined-10-turn-plan-turn-414.md`.  Written turn 414
after locking the nine architectural pillars (Q1–Q9) and studying
imgui.h (602 fns) + implot.h (157 fns, 26 plot types, 15 635 LOC).

This is a five-tier plan covering ~98 turns.  Each tier has a
single shipping goal so progress is visible turn-by-turn.

---

## 0. Executive summary

| Tier | Turns | Goal | Net code add | Tests added |
|---|---|---|---|---|
| 1. Architectural pillars | 415–428 (14) | Q1–Q9 + 3 seeds + MVP plot smoke + snapshot infra | ~3 800 LOC | ~115 |
| 2. Imgui parity completion | 429–457 (29) | All remaining P-phases ✅ (minus showDemoWindow → Tier 4) | ~5 200 LOC | ~205 |
| 3. Secondary primitives | 458–472 (15) | Adaptive layout, gestures, `Bind(T)`, knobs, spinners, toggle, markdown, toast, hotkeys, date+file pickers | ~2 500 LOC | ~85 |
| 4. Implot D-expanded port | 473–497 (25) | Full plot subsystem inside ui.zig + showDemoWindow | ~5 500 LOC | ~145 |
| 5. Capstone + polish | 498–511 (14) | Examples, audit, archive, next-arc plan | ~2 500 LOC | ~50 |
| **Total** | **98 turns** | **All shipped** | **~19 500 LOC** | **~600** |

Net ui.zig at arc close: ~55 KLOC, single flat file, no module-
qualifier indirection, no @This tricks.  Test suite ~2 270 tests.
Lint: zero issues across all files.  Examples: 40+ phone-friendly
+ desktop demos, half of which are <200 LOC apiece thanks to the
secondary primitive landing in Tier 3.

The plan front-loads pillars (Tier 1) before parity (Tier 2)
because Q1, Q2, Q3, Q7 are prerequisites for clean implementation
of P9, P16 (input), and P17 (validation).  Implot lands LAST
(Tier 4) because it consumes every pillar — by then the foundations
are battle-tested across ~50 turns of real use.

---

## ⏸ RESUME POINT — paused after turn 443

**Last completed:** Turn 443 (P10.1 ColorEdit display format).

**Test count:** 1864/1864 pass.  Lint: 0 issues in 151 files.
Wasm + TS bundle: clean.

**Pause reason:** taking a break from the imgui completion arc.
Pick up whenever — the codebase is at a clean checkpoint.

### What just shipped (most recent session arc)

The P9 InputText polish family + the start of P10 ColorEdit:

| turn | what | tests |
|---|---|---|
| 438 | P8.8 table query methods (`tableGetColumnIndex/Count/Name/Flags`) | +3 |
| 439 | P9.1 declarative char filters (`chars_decimal/hex/scientific/uppercase/no_blank`) | +8 |
| 440 | P9.2 behavior flags host path (`enter_returns_true`, `escape_clears`, `password_mask`, `read_only`, `allow_tab_input`) | +11 |
| 440b | Phone example `ui_input_flags_zoo_phone.zig` | — |
| 440c | **bug-fix**: P9.1 filters didn't run on web; JS-side mirror added | +1 |
| 441  | Multiline P9.2 host path + `ctrl_enter_for_newline` | +5 |
| 441b | Multiline `<textarea>` DOM overlay (10 JS bindings) | — |
| 441c | Cosmetic: escape `\n`/`\t` in phone-example readouts | — |
| 442  | P9.3 callback contracts pinned + honest web-path docs | +8 |
| 442b | `ui_notes_phone.zig` (Q8 + edit callback + textarea overlay) | — |
| 443  | P10.1 ColorEdit display format (`.float` / `.int_0_255` / `.hex`) | +7 |

Net: 1820 → 1864 tests (+44).  Major new infrastructure: P9.1
JS-side char filtering, the `<textarea>` DOM overlay, the
declarative behavior flag set, and the format-helpers for hex
color rendering.

### Outstanding loose ends (handle WHEN we resume, not before)

- **Q8 persistence-on-web verification.**  `ui_notes_phone.zig`
  was tested on phone by opening the HTML directly from
  `content://` URI; localStorage on that scheme is restricted
  by Chrome on Android.  Need to verify Q8 actually round-trips
  via a real HTTP server (e.g. `python3 -m http.server` on
  desktop, or a hosted URL).  Not a zimr bug — a browser/origin
  quirk — but the *feature* is untested end-to-end on web.
- **Web-path parity for `char_filter` / `completion` / `history`
  callbacks** (turn 442 documented these as host-only).  Each
  needs a JS-side keydown listener that calls a wasm export.
  Defer until a real product needs them.
- **Overlay element duplication** in `src/web/zimr.ts`: ~150 LOC
  of sibling `<input>` vs `<textarea>` machinery.  Right
  unification point isn't obvious until a third overlay
  appears (probably the `textEditor` arc in §4b).  No action
  yet.
- **Custom `colorEdit` precision** — `opts.fmt` is deprecated
  but a precision-enum replacement should land if a real caller
  needs anything other than `{d:.2}`.  Not urgent.

### Resume here → Turn 444 (P10.2 ColorEdit suppression flags)

See "Turn 444" entry below in §2.  TL;DR for resumption:

- Imgui has `NoAlpha`, `NoPicker`, `NoOptions`, `NoSmallPreview`,
  `NoInputs`, `NoTooltip`, `NoLabel`, `NoSidePreview`, `NoDragDrop`.
- Map to zimr opts fields (skip flags that don't apply to
  zimr's current layout — e.g. `NoDragDrop`, `NoSidePreview`).
- Likely scope: `no_label`, `no_swatch`, `no_inputs`,
  `no_tooltip` (4 fields).  Confirm at turn start by re-reading
  imgui's flag docs.
- Wire into `colorEditNFloat` rendering branches; each flag
  suppresses one visual affordance.
- +5-6 tests.

After 444: 445 (P10.3 alpha + HDR), 446 (P10.4 Color converter
methods), 447 (P11 Selectable callback redesign).  Tier 2
continues through turn 457; Tier 3 (`Bind(T)`, knobs, spinners,
toggle, markdown, toast, hotkeys, date+file pickers) starts
turn 458.

### How to resume cleanly

1. `cd /home/claude/work/Zimr` (or wherever the workspace lives).
2. `zig build test --summary all` → expect 1864/1864 pass.
3. `zig build lint-check` → expect 0 issues in 151 files.
4. Read this section + the Turn 444 entry below.
5. Read the relevant imgui range (`/tmp/imgui-master/imgui.h:776-790`
   ColorEdit/Picker family) before writing code (rule §1.0.1).
6. Execute the audit gate at turn close (§1.0.9).

The most recent zip is at `/mnt/user-data/outputs/zimr-turn-443.zip`
if a full snapshot is needed.

---

## 1. Cross-cutting principles (apply to every turn)

### 1.0  Execution rules (the operational floor)

Codified turn 414 after the fresh-eyes review.  Every turn obeys
these without prompting:

1. **Read the source first.**  Before any imgui-derived
   implementation, view the relevant `/tmp/imgui-master/imgui.h`
   / `imgui_widgets.cpp` / `imgui_tables.cpp` range.  Same for
   `/tmp/implot-master/implot.h` / `implot.cpp` during Tier 4.
   Cite `file:LINE` in the changelog body.  (Codified turn 411,
   reaffirmed here.)

2. **Changelog mid-turn, not end-of-turn.**  Open the changelog
   entry at the FIRST file edit of a turn, with the title + 1-
   line goal.  Add a bullet per substantive change as it lands.
   An interrupted half-written entry is much better than a
   completed turn with no record.  If the session is cut at 70%
   tool use, the changelog still has 70% of the turn's truth.

3. **Selective testing.**  Default: `zig test src/ui.zig` (or
   the file under edit) only.  Full `zig build test --summary all`
   runs at turn close, not after every edit.
   `python3 scripts/build_standalone.py X` runs only when the
   example or its public-API surface changed.  Lint-check runs
   at turn close.

4. **80% tool-use budget per turn.**  At ~80% of tokens used,
   stop adding scope: ship what's done, write the changelog,
   save the zip, defer the rest to the next turn with a clear
   continuation note.  The plan's per-turn estimates assume this
   cap.  Bigger turns auto-split into two.

5. **Phone examples ship standalone-buildable.**  Every
   `examples/*_phone.zig` includes the `python3 scripts/build_standalone.py X`
   invocation in the changelog body, plus the output HTML path
   so the file can be opened directly on a phone for testing.

6. **Style guide before linter.**  Read
   `src/notes/style-guide.md` (or whatever guide exists) and
   apply rules preemptively.  The linter is a safety net, not
   the primary mechanism.  If a style violation comes up, the
   fix goes into the style guide so it won't reappear.

7. **Verify diffs after edit.**  After a `str_replace` /
   `create_file`, re-view the affected range to confirm the
   change is what was intended.  Catches subtle off-by-one in
   patches before they become silent bugs.

8. **Save zip LAST.**  After tests, lint, changelog, plan ✅ tag.
   Prune cadence: keep multiples of 10 + the 3 most recent
   distinct turn zips.  Disk budget: < 1 GB total across
   `/mnt/user-data/outputs/`.  **Exclude pattern** (turn 415b
   tightened this — old `*/prebuilt/standalone/*.html` left 56 MB
   of wasm files per zip; wider `*/prebuilt/*` cuts zip 27 MB → 9 MB):
   ```
   -x '*/.zig-cache/*'
   -x '*/zig-out/*'
   -x '*/prebuilt/*'
   -x '*/tools/zig-x86_64-linux-0.16.0/*'
   -x '*/tools/bun-linux-x64/*'
   -x '*/.git/*'
   ```

9. **End-of-turn audit gate.**  Before zip: tests pass, lint
   zero, changelog complete, plan doc tagged with the turn's
   outcome.  No exceptions.

10. **Don't trust memory; trust files.**  At turn start, read the
    relevant plan section + the previous changelog entry.  Don't
    rely on "I remember what I was doing."

11. **New public APIs need both host tests AND a wasm32 example.**
    Host tests on `std.testing.allocator` (64-bit) pass on hashes
    or sizes that silently break under wasm32 (`usize` ≠ `u64`,
    different alignment).  Ship a phone-runnable example
    exercising the API path before considering the pillar done.

### 1.1  Flat & explicit


- **No `@This()` self-aliases.**  Bare references for top-level
  symbols.  (Re-established turn 414.)
- **Single file**: ui.zig grows; we don't split it.  Persistence,
  dock, plots — all in.
- **No new modules** unless the boundary is fundamental
  (`runtime.zig` for raylib port, `math.zig` for linalg, etc.).
- **Module-level constants over enums for "single flag"** —
  prefer `pub const STRIPED_ROW_ALPHA: f32 = 0.04` to
  `RowStyle.striped_alpha` field on a single-purpose struct.

### 1.2  Ziggy patterns to lean into

| Pattern | Where it pays |
|---|---|
| `comptime T` typed maps | Q2 state storage, Q9 anim slots, future plot item lists |
| `inline for (fields(StyleField))` | Q5 style-guard restoreInto, Q8 persistence auto-serialize |
| `defer guard.restore()` | Q5 style scoping, future scope-bracketed everything |
| `union(enum)` for plot items | Q6 implot — one storage, one iteration loop |
| `?T` optional fields in opts | Already idiomatic.  Continue: every opts struct, every Q5 PartialStyle |
| `BoundedArray(T, N)` | Per-frame plot items, animation slots, registered axes |
| Type-state for begin/end | `beginPlot → ?PlotCtx` where `PlotCtx.endPlot()` is the only way out.  Misuse becomes a compile error. |
| Sentinel-terminated strings for C interop | runtime FFI; nothing in ui.zig should leak into this concern |
| `comptime` validators in P17 | Format strings, range opts, ID literals |

### 1.3  Testing strategy

| Test class | Cadence |
|---|---|
| Unit tests for new primitives | Every turn that adds public API |
| Regression tests for fixed bugs | Every bug fix (mandatory) |
| Integration tests via `examples/` | Phone + desktop examples are NOT tests; tests are unit-level |
| Schema-version round-trip tests | Every Q8 persistence schema bump |
| Comptime tests for P17 validators | Use `comptime { _ = validate(...) }` patterns |

Target: each turn adds 5–15 tests.  Net at arc close: ~2 270 tests
from current 1 687.

### 1.4  Documentation strategy

- **Cheatsheet (`src/notes/CHEATSHEET.md`)**: regenerated each turn
  that adds public API.  Single source of truth for "what can I
  call?".
- **Changelogs**: one entry per turn, in
  `src/notes/changelogs/changelog{N}-{N+9}.md`.  Header lists
  what shipped, body has rationale.
- **Plan updates**: this document gets a 1-line outcome tag per
  finished turn, and a full refresh every 20 turns.
- **Example READMEs**: each new `examples/X.zig` opens with a 5-
  line doc comment explaining what to look at.
- **No external docs site**.  ui.zig comments + notes + examples
  are the entire documentation.

### 1.5  Lint policy

Existing 10 lint rules + 4 more planned in P17.  Lint is a hard
gate (every turn must end with zero issues).  When adding a
lint rule, also add a "lint-suppress" mechanism in the affected
opts struct so explicit-intent code can opt out without a fork.

### 1.6  Cadence for "did we drift" reviews

- Turn 428 — Tier 1 review (architectural pillars audit)
- Turn 464 — Tier 2 review (imgui parity audit)
- Turn 473 — Tier 3 review (secondary primitives audit)
- Turn 498 — Tier 4 review (implot completeness audit)
- Turn 512 — Final.  Arc-close audit, plan archive, next plan.

---

## 2. Tier 1 — Architectural pillar landing (turns 415–431)

Goal: ship Q1–Q9 + the clever-but-not-too-clever seeds as live
infrastructure in **14 turns** (slack added after fresh-eyes
review — was 12, but Q2 comptime subtleties or Q4 transform
math could realistically take 2 turns).

### Turn 415 — Q1 input layer (key-state array + capture flags) ✅

**Deliverable**: `InputSnapshot.keys: [@intFromEnum(KeyCode.MAX)]KeyState`
replaces the hardcoded `key_X: bool` fields.  Public Ui helpers:
`u.isKeyDown(.X)`, `u.isKeyPressed(.X)`, `u.isKeyReleased(.X)`,
`u.isKeyPressedOrRepeat(.X)` (text-input semantics), `u.isShiftDown()`,
`u.isCtrlDown()`, `u.isAltDown()`, `u.isSuperDown()`.  Free fns for
ctx-without-Ui callers: `ctxKeyPressedOrRepeat`,
`snapshot{Shift,Ctrl,Alt,Super}Down`.  beginFrame populates via
`inline for (fields(KeyCode))` loop.

**Discovery turn 415 (plan correction)**: the originally-planned
`u.wantCaptureKeyboard()` / `u.wantCaptureMouse()` helpers ALREADY
EXIST at src/ui.zig:6163-6190 as computed methods:
- `wantCaptureKeyboard()` returns `self.ctx.active_id != 0`
- `wantCaptureMouse()` hit-tests mouse against `frame_windows`

The static-flag design originally proposed was unnecessary.  The
existing computed approach is fine and ships unchanged.  ADR
comment on `UiContext` documents this.

**Imgui ref**: `imgui.h:2481-2487` (`ImGuiKeyData`),
`imgui.h:2690` (`KeysData[ImGuiKey_NamedKey_COUNT]`),
`imgui.h:1097-1099` (`IsKeyDown/IsKeyPressed/IsKeyReleased`).

**Backwards compat**: `chars_typed` queue kept.  Mouse edge-event
bools (`mouse_left_clicked` etc.) kept — they're per-frame edge
events, not "level" key state.

**Tests shipped**: 10 total (was planned 10).  6 in turn 415:
KeyCode.MAX sentinel, fromRaylib round-trip, fromRaylib null on
unsupported, KeyState default zeros, InputSnapshot.keys
defaults, edge-event truth table.  4 in turn 415b: toRaylib
inverse round-trip, keyEventSnapshot test helper shape,
modifier-helpers aggregate left+right, synthetic injection via
beginFrameRaw.

**Carmack wins**: the 15 hand-written key reads in beginFrame
collapse to one `inline for` loop.  4 verbose modifier-OR sites
collapse to `snapshot*Down(&ctx.input)` calls.  13 `(Ui{ .ctx = ctx
}).isKeyPressedOrRepeat(.X)` sites collapse to
`ctxKeyPressedOrRepeat(ctx, .X)`.  Net: ~50 LOC removed via
helper introduction.

**Example shipped**: `examples/ui_input_query_demo.zig` (phone-
friendly AppBridge demo, ~150 LOC).  Live readout of every key
state + mouse + modifiers + capture flags.  Standalone built via
`python3 scripts/build_standalone.py ui_input_query_demo` → 712 KB
HTML at `prebuilt/standalone/ui_input_query_demo.html`.

### Turn 416 — Seed D: `z.features` flag struct + seed E: `z.todo()` ✅

Two of the clever-but-not-too-clever seeds land before Q2.  Cheap,
unlocks the rest:

**`z.features`**: a single comptime struct in ui.zig:
```zig
pub const features = struct {
    pub const persistence_to_disk = true;   // existing
    pub const canvas = false;               // flips at turn 422
    pub const animation = false;            // flips at turn 424
    pub const implot = false;               // flips at turn 472
    pub const adaptive_layout = false;      // flips at turn 458
};
```
Examples can `if (z.features.implot)` to optionally include plot
content.  Lint rule (new): warn on code referencing a disabled
feature.  Lets us land pillars incrementally without breaking
examples.

**`z.todo(@src(), "description")`**: formalizes the existing
`warnOnce` pattern.  Single grep target for "what's stubbed."
Compiles to nothing in release; warns once + appears in the
future `u.showMetricsWindow` in debug.

Plus **seed F**: ADR comments.  Every pillar's first public-API
landing gets a `// ADR: Q4 canvas, decided turn 414, see
big-plan-turns-415-510.md §2.Q4` comment near the public API.

**Tests** (4): features struct exists, todo() compiles to no-op
in release, ADR-comment lint rule (new) flags missing rationale.

**Risk**: very low.  All additive, no churn.

### Turn 417 — Q2 state storage (typed generic helper) ✅

**Deliverable**: `u.getState(T, id)` / `u.putState(T, id, value, opts)`.
Internal: `ctx.ext_storage: AutoHashMapUnmanaged(usize, *anyopaque)`
keyed by `@typeName(T)` hash.  Each type T gets a lazily-allocated
`AutoHashMapUnmanaged(Id, T)`.

**Tests** (8): get-or-put round trip, type isolation (two types
with same id are independent slots), lazy allocation (no map
created until first putState), get on never-put returns null, put
overwrites prior, putState returns pointer to slot, multi-type
mixed access, zero-allocation when no extension uses it.

### Turn 418 — Q3 widget API primitives (B path: imgui-style) ✅

**Deliverable**: `u.itemSize(size)`, `u.itemAdd(rect, id) → bool`,
`u.buttonBehavior(rect, id, opts) → ButtonResult{pressed, hovered, held, just_activated, just_deactivated}`.  Public, documented.

**Imgui ref**: `imgui_internal.h:3220-3260` ItemAdd, ButtonBehavior.

**Tests** (12): itemAdd respects clip rect (returns false when
fully clipped), buttonBehavior fires once per click,
just_activated/just_deactivated edge events, button_repeat flag
respected, item_size advances cursor correctly, integration with
Q1's input layer (uses `u.isMouseDown` not `ctx.input.mouse_left_down`).

**No example yet** — turn 418 ships the example with the C path.

### Turn 419 — Q3 widget API primitives (C path: single-call) ✅

**Deliverable**: `u.beginItem(label, opts) → ?ItemCtx{id, rect,
hovered, pressed, held, just_activated, just_deactivated}` and
`u.endItem(ctx)`.  Internally calls itemSize + itemAdd +
buttonBehavior.

**Example**: `examples/ui_custom_widget.zig` (desktop) — implements
`u.starRating("rating", &state, 5)` as a reference custom widget
using ONLY the new primitives.  Doubles as the doc for "how to
write an extension widget."

**Tests** (6): begin/end pairing (`defer u.endItem(...)`), null
return when clipped, ItemCtx all-fields-populated, integration
with state storage (custom widget stores hover-animation state in
Q2 slot).

### Turn 420 — Q7 drawing primitives (arcs + polygon) ✅

**Deliverable**: `dl.addArc(center, radius, a0, a1, col, thickness, segments)`,
`dl.addArcFilled(center, radius, a0, a1, col, segments)`,
`dl.addPolygon(points, col)`.  Plus an `addRoundedRectMixed`
variant if testing shows the existing `addRectFilled` rounded-
corner support is missing per-corner control.

**Tests** (10): arc spans (0° to 360°), arc with thickness >
radius (caps cleanly), filled arc (pie slice shape),
addPolygon convex check, addPolygon with collinear points (no
NaN), arc segment count auto-derives from radius if 0.

**Convention**: angles in radians, 0 = +X, CCW positive.  Matches
math.zig.

### Turn 421 — Q5 style override guard (defer-RAII) ✅

**Deliverable**: `StyleGuard`, `PartialStyle`, `u.styleOverride(overrides)`.
Generated via comptime `inline for (fields(Style))` to build the
PartialStyle struct + restoreInto fn.

**Tests** (8): override-and-restore round trip (no diff), nested
overrides restore correctly, partial overrides leave untouched
fields, restore is idempotent, errdefer-safety (style restored even
on early return / error), no-op when PartialStyle is empty.

### Turn 422 — Q4 canvas widget (with transform stack) ✅

**Plan deviation (turn 422)**: original packaging was over-scoped
for one turn.  Split:
- **422 ✅**: lifecycle (`beginCanvas` / `endCanvas`),
  `CanvasCtx.drawList()`, `CanvasCtx.localMouse()`,
  `CanvasCtx.hovered()`, push/pop clip via existing DrawList
  primitives.  6 tests.
- **422b ✅**: transform stack — `pushTransform(translate,
  scale)` / `popTransform()`, nested compose, `localMouse`
  applies inverse transform, `currentTransform()` accessor.
  11 tests.
- **422c ✅**: `examples/ui_canvas_demo.zig` minimal
  node editor (3 draggable boxes + bezier connections, pan + wheel
  zoom) + canvas hover guard (canvas hovered = mouse in rect AND
  parent window is topmost at mouse position).  1 test + 1
  shipped phone-testable standalone HTML.

**Deliverable**: `u.beginCanvas(label, size, opts) → ?CanvasCtx`,
`u.endCanvas(canvas_ctx)`, `canvas.pushTransform(translate, scale)`,
`canvas.popTransform()`, `canvas.localMouse() → Vec2`,
`canvas.drawList() → *DrawList`.  Clip rect pushed to canvas bounds,
mouse coords transformed through the stack.

**Imgui ref**: imgui has no canonical canvas, only patterns
(BeginChild + manual clip + GetWindowDrawList).  zimr's canvas IS
the canonical primitive.  Internally a canvas reuses the splitter
pattern (P7.2) with its own channel pair for clipped draws.

**Tests** (10): local mouse coords match cursor (no transform),
transform translate/scale affects draw cmds, nested transforms
compose, transform pop restores prior, clip rect respected by
addRect, hover guard (canvas hovered = mouse in rect AND no
sibling popup covering it).

**Example**: `examples/ui_canvas_demo.zig` (desktop) — minimal
node editor: 3 boxes draggable in the canvas, connected by
bezier lines.  ~200 LOC, proves the canvas primitive is enough.

### Turn 423 — Q8 persistence integration (opt-in flag + auto-serialize) ✅

**Deliverable**: `u.putState(T, id, value, .{.persist = true})`.
Comptime-generated zon serialize/deserialize for plain-data T's.
PersistedState gets an `ext_state` typed bag.  Serializer walks
`ext_storage` entries marked persist; calls comptime serialize fn
per type; payload includes a typed entry per persistable type.

**Imgui ref**: imgui has `ImGuiStorage` but it's int/float/ptr
only.  zimr's typed comptime approach is more powerful.

**Tests** (12): plain struct round-trip, struct with array round-
trip, struct with enum round-trip, struct with BoundedArray round-
trip, mixed persistable + non-persistable in same context, schema
version mismatch silently discards (matches existing policy),
unknown extension type silently discarded (forward-compat),
extension type with pointer fails to compile with clear message,
quota-exceeded error swallowed (matches existing policy).

### Turn 424 — API cleanup: canvas coords, drawlist surface, ui re-exports ✅

Three small but real API-shape issues surfaced while landing
Q4 + Q8.  We have all year and breakage doesn't matter; these
keep paying tax every time anyone writes against the surface, so
they get fixed before more code depends on the current shape.

**Deliverable 1**: rename `CanvasTransform.applyPoint(p)` →
`CanvasTransform.toLocal(p)`.  The name `applyPoint` reads as
"transform this point" but returns canvas-LOCAL coords, not
screen — wrong default that bit the node-editor example.
`toLocal` says what it does.  `c.toScreen(p)` (turn 422c) stays
as the canonical "I want to draw this" projection.  Audit call
sites: only `c.toScreen` uses `applyPoint` internally today; the
example was updated turn 422c to use `c.toScreen` directly.
Lint rule (optional): warn if `currentTransform().applyPoint(...)`
appears in a draw context — but a rename + good doc comment is
probably enough.

**Deliverable 2**: forward every `DrawList` primitive onto
`DrawListHandle` via a comptime `inline for` over DrawList's
public methods.  Today DrawListHandle exposes ~8 methods;
DrawList has ~25.  Reaching `c.drawList().list.addBezierCubic(...)`
to use the missing ones is wrong — `.list` is an implementation
detail.  Either explicitly add every passthrough or generate
them.  Generate.

**Deliverable 3**: re-export `Color` and `Rectangle` from
`ui.zig` so extension authors can use `ui.Color` / `ui.Rectangle`
without reaching for `z.Color`.  Today `ui_custom_widget.zig`
example has to mix `ui.X` and `z.Y` references awkwardly.  Just
add the re-exports.

**Deliverable 4** (cheap, pile on): add `Ui.drawRectFilled(rect,
col: Color) void` convenience that wraps the colorToU32 +
getForegroundDrawList + addRectFilled chain.  Every custom widget
wanting a colored rect writes this same sequence.

**Tests** (~8): toLocal rename works (find/replace) and old name
removed; DrawListHandle has every primitive; ui.Color and
ui.Rectangle are reachable; drawRectFilled draws.  Most of this
turn is mechanical churn — the test count is small because the
behavior is identical to before, only names changed.

### Turn 425 — `putState` init-if-absent semantics + named idiom ✅

Discovered turn 423: `u.putState(T, id, initial, .{})` overwrites
every call, so the documented `getState orelse putState` idiom
is the ONLY safe way to do "load OR initialize."  For
persistable state this is critical — calling `putState` after
`apply` blew away the loaded value, which is exactly what the
first Q8 test runs hit.

This is a footgun.  Fix by splitting into two clear methods:

- `u.initState(T, id, initial)` — "make sure (T, id) has SOME
  value; if it already does, leave it.  Returns the pointer to
  whatever's there."  Allocates the slot on first call.
- `u.setState(T, id, value)` — explicit overwrite.  Symmetric
  with the `init` half of the API.
- `u.putState` keeps its current overwrite-every-call semantics
  but is now the explicit choice for "I want to overwrite."
  (Or: rename `putState` → `setState` and delete the redundant
  name.  Cleanest, breaks every existing call site.  We have
  all year — do it.)

Tests already exercise the round-trip via `getState orelse
unreachable` (turn 423).  Add ~4 tests for the new
`initState` semantics: first call stores, second call returns
existing without overwriting, opt-in persist flag still works.

**Migration**: every existing `putState` call site with `.{}`
initial-value is a candidate for `initState`.  Most live in
Q2 / Q4 / Q5 internals — straightforward find+update.

### Turn 426 — Carmack sweep: migrate built-in widgets to Q3 primitives + ext_storage ✅

The Q3 primitives (turn 418) and Q2 generic storage (turn 417)
exist precisely to be used.  Today the built-ins reimplement
both inline.  We have ample test coverage to catch regressions
(1776 tests by turn 423).  Migrate.

**Widget migration** (Q3 primitives — `itemSize` / `itemAdd` /
`buttonBehavior`):
- `buttonImpl`
- `checkboxImpl`
- `radioButtonImpl`
- `smallButtonImpl`
- `arrowButtonImpl`
- `selectableImpl`

Each reimplements press/release/hovered-id state inline.
Migrate one widget at a time, run full test suite between each,
green-or-revert.  Bit-for-bit behavior preservation is the
test guarantee.

**Typed-state migration** (Q2 generic ext_storage replacing
hand-rolled fields on UiContext):
- `tab_bar_state`
- `combo_state`
- `table_sort_state`
- `table_scroll_state`
- `table_width_auto_cache`

Each is a typed `AutoHashMap(Id, X)` glued onto UiContext.  Q2's
`getState`/`putState` is the right shape — move them and delete
the bespoke fields.  Q8 (turn 423) is already wired so anything
opting into persistence gets it free.

**Tests**: existing coverage; no new test additions expected.
Test count holds at ~1776 ± a few.

**Risk note for me**: this turn is a refactor, not new
functionality.  If a migration breaks something subtle, revert
that widget's migration and add a focused test that reproduces
the failure mode.  Don't try to fix-forward into a hybrid state.

### Turn 427 — Q9 animation primitives (tween + spring) ✅

**Deliverable**: `u.animated(label, .{from, to, duration, easing,
delay}) → f32`, `u.spring(label, .{target, stiffness, damping,
initial}) → f32`.  AnimationSlot stored in Q2.  Reuses easings.zig
curves.

**Tests** (12): tween linear interpolation, tween ease_out shape,
tween delay (returns from-value during delay), tween clamped to
to-value after duration, spring approaches target, spring with
mid-flight target change (interruptible), spring at rest (current ≈
target within epsilon), spring with damping critical/under/over,
animated and spring co-exist with different labels, animations
persist via Q8 if opted in (rare but possible).

**Easings shim**: ui.zig has
```zig
fn applyEasing(e: Easing, t: f32) f32 {
    return switch (e) {
        .linear => easings.linear(t),
        .ease_in => easings.cubicIn(t),
        .ease_out => easings.cubicOut(t),
        .ease_in_out => easings.cubicInOut(t),
        .back => easings.backOut(t),
        .elastic => easings.elasticOut(t),
    };
}
```
The `Easing` enum is the curated public surface (6 options);
easings.zig has 25 functions — extension authors can call
`easings.bounceOut` directly if they want, the enum is just for
common use.

**Example**: `examples/ui_animation_gallery.zig` (desktop) — 12
knobs showing each easing.  Already in old plan; this is its turn.

### Turn 428 — Phone keyboard hint (HTML inputmode bridge) ✅

**Deliverable**: `InputTextOpts.input_mode: InputMode = .text`
field, enum of `text/numeric/decimal/email/tel/url/search`.  When
input is focused, runtime sets the browser's `inputmode`
attribute on a hidden DOM input that catches IME / mobile-keyboard
input.

**Imgui ref**: imgui has no equivalent — it's browser-specific.
zimr does because it targets wasm-first.

**Tests** (4): inputmode attribute set on focus, cleared on blur,
mapped correctly from enum (.numeric → "numeric"), no-op on
desktop platforms.

**Runtime side**: small JS extern that takes a mode string,
applies to the hidden DOM input element.  ~30 LOC of JS.

**Example fixture**: integrated into the next phone example
(turn 432 unit converter).

### Turn 429 — MVP plot smoke test (validate canvas+arcs+state+style compose) ✅

**Fresh-eyes insertion (turn 414 review).**  Tier 4 doesn't ship
until turn ~471.  Q4 canvas (turn 422) compounding "we built X on
top of it" for 49 turns before validation is too long.

This turn lands a **~120 LOC stub plot**: `u.miniPlot(rect, xs, ys)`
that draws a single line plot in a canvas.  No items list, no
setup family, no axes labeling — just enough to validate that the
primitives compose.

**Pillars exercised**:
- Q4 canvas (the plot lives in one)
- Q7 arcs (used for the mid-line indicator dot)
- Q2 state storage (axis auto-fit limits cached per id)
- Q5 style guard (the plot pushes its own bg/grid override)
- Q1 input (`u.isKeyPressed(.r)` resets axis fit)
- Q9 animation (`u.spring` on the limits when they change)

If any pillar feels wrong here, fix it NOW — before 49 turns of
compounding.  The smoke test is THROWAWAY: turn 475 replaces it
with the real `beginPlot` / `endPlot`.  Comment marks it as
`@deprecated_at_turn_472` so future code can grep it.

**Tests** (4): smoke renders, auto-fit limits set on first frame,
reset on R-key, all pillars actually called (assert
ctx.frame_anim_slots populated, ctx.ext_storage populated, etc.).

**Example**: `examples/ui_mini_plot_smoke.zig` (desktop, ~100 LOC).
NOT a phone example — it's a validation tool, not a deliverable.

### Turn 430 — Snapshot rasterize testing infrastructure ✅

**Fresh-eyes insertion.**  Visual regressions are caught by
nothing today.  This turn adds a CPU rasterize → byte-compare
pipeline.

**Deliverable**:
- `scripts/snapshot_test.py`: takes an example name, runs the
  example for N frames (via existing standalone harness), captures
  the final draw list, rasterizes to a 800x600 RGBA buffer (via
  the existing software fallback path or a simple deterministic
  rasterizer), saves to `tests/snapshots/{example}.png`.
- `tests/snapshots/` directory with reference images.
- CI-style check: re-run the rasterize, diff against reference,
  fail if non-trivial diff (>0.1% of pixels deviate).

**Coverage**: every example that's not phone-touch-driven (touch
input would make snapshots flaky).  At turn 428, that's ~12
examples.  By turn 506, ~25.

**Tests** (3): smoke that the harness runs, that a trivial diff
fails, that a no-diff passes.

### Turn 431 — Tier 1 review + cheatsheet refresh ✅

**Deliverable**: ✅ tag each of Q1–Q9 in this plan doc with the
turn that shipped it.  Update CHEATSHEET.md with the ~40 new
public symbols.

Audit questions to answer in writing:
- Did any pillar's API differ from what we sketched?  Document deltas.
- Are there inter-pillar surprises?  (e.g. Q4 canvas needed an
  extra method we didn't anticipate.)
- Which Tier 2 phases now have prerequisites met?  Verify P9
  (InputText) can lean on Q1 fully.

**Output**: `src/notes/tier1-architectural-pillars-review.md` (~5KB).

### Turn 432 — P8.5 scroll flags finish ✅

(Carried over from old plan.) Clip-rect generalization, shift-
wheel horizontal pan, persist scroll_x offset, horizontal
scrollbar UI.  +6 tests.

**Phone example**: `ui_data_grid_phone.zig` — touch-friendly
H+V scroll dashboard.

### Turn 433 — P8.6 part 1 (sort suppression flags) ✅

Plan listed 8 flags; honest scope was 4.  `no_resize`,
`no_reorder`, `no_hide`, `default_hide` all suppress features
that don't exist yet (user-resize, drag-reorder, hide-column).
Backlogged with "needs feature first" trigger.

Shipped: `no_sort` (rename of `sortable`, flipped polarity to
match imgui), `no_sort_ascending`, `no_sort_descending`,
`default_sort: ?TableSortDirection`.  +6 tests.

**Desktop example**: deferred — `ui_kanban_board.zig` per plan
wants drag-drop card support, which is another absent
prerequisite.  Folded into a future turn once drag-drop lands.

### Turn 437 — P8.6 part 2 (display flags, honest scope) + P8.7 deferred ✅

Plan listed 6 column flags + angled headers.  Audit revealed
4 of the 6 flags + angled headers all suppress / extend
features that don't exist yet (per-column indent system,
per-cell clip rect, header text not measured into widths,
text-rotation primitive).  Shipped 2 honest flags
(`width_auto`, `no_header_label`); backlogged the 4 deferred
flags + angled headers.

**Phone example**: `ui_pomodoro_phone.zig` — 25-min timer +
progress ring, uses Q9 `u.animated` to drive an accent →
warning colour transition over 2 seconds when the timer
enters its final 60 seconds.

### Turn 437b — Engine fixes (drawTriangleStrip + drawTriangle) + touch-pan + primitives zoo ✅

Three rendering pieces shipped together, each surfaced by
phone-testing.

`drawTriangleStrip` was emitting RL_TRIANGLES with no shapes
texture binding — invisible in the WebGL2 batch shader.
Rewritten to use RL_QUADS (raylib's `rshapes.c` canonical
pattern) by decomposing ribbon-style strips into quads with
proper shape-rect UVs.  Cascade: `shapes_state` threaded
through 7 internal drawing.zig functions, 10 example sites,
and 5 ui.zig replay sites.  Fixes addLine, addArc, addPolyline,
addBezier, addSpline*.

`drawTriangle` was using RL_QUADS with vertex duplication that
produced ONE real + ONE degenerate indexed triangle.  WebGL2's
textured-shapes batch path apparently needs BOTH indexed
triangles in a quad to rasterize fragments — even when one is
redundant overdraw.  Reworked to emit `(v1, v2, v3, v2)` which
produces two REAL triangles with opposite winding (matching
`drawPoly`'s already-working wedge pattern).  Same triangle
drawn twice; wasteful but reliable.
Fixes addTriangleFilled, addQuadFilled, addPolygon, addArcFilled.

Touch-pan scroll added to `closeWindow`: hovered window +
content overflow + `active_id == 0` + left-mouse held → drag
delta becomes scroll_y/scroll_x.  Captured at gesture start;
deactivates on release.  Phones don't emit wheel events from
finger drags, and the 10 px scrollbar thumb (32 px hit rect)
is findable but not discoverable on mobile.  +2 unit tests.

Phone example `ui_primitives_zoo_phone.zig`: 15 cards covering
every drawList primitive, each labelled with what to expect.
Scroll, see anything blank or wrong.  Animated phase drives
moving primitives so frame-stuck ones are catchable.

Tests: 1819 → 1821.  Lint: 0 issues in 149 files.

### Turn 438 — P8.8 table queries ✅

`tableGetColumnIndex`, `tableGetColumnCount`, `tableGetColumnName`,
`tableGetColumnFlags`.  Pure-read accessors against the active
table state, plus a `TableColumnFlags` return struct for the
queryable subset of column opts (no_sort, no_sort_ascending,
no_sort_descending, no_header_label, default_sort).

**Deferred**: `tableGetColumnUserId` — no `user_id` field exists
on `TableColumnOpts`.  Backlogged to §13 with trigger
"shipped once columns gain a tagged user-id slot for sort
callbacks."

**Tests** (+3): one combined Count+Index test (active-table-or-null
behavior + cur_col tracking), one Name test (lookup + out-of-range
null), one Flags test (per-column flag round-trip).

### Turn 439 — P9.1 InputText character filters ✅

`chars_decimal`, `chars_hexadecimal`, `chars_scientific`,
`chars_uppercase`, `chars_no_blank` opts on `InputTextOpts`.
Applied via a new internal `applyCharsFlagFilters` that runs
BEFORE the user's `char_filter` callback.  `chars_uppercase`
rewrites in place; the other four are reject-on-no-match.
Multi-flag composes (intersection of accept sets).  +8 tests.

### Turn 440 — P9.2 InputText form-flavor behavior flags ✅

Ship 5 flags, both paths (host edit engine + web DOM attribute):
`enter_returns_true`, `escape_clears`, `password_mask`,
`read_only`, `allow_tab_input`.  Each flag's host path runs in
unit tests; each flag's web path sets the corresponding HTML
attribute on the overlay element via a new JS call.

**Deferred** (with backlog entries):
- `auto_select_all` — needs minimum selection-rect on host
  path.  Lands with the textEditor arc where we build real
  selection state.
- `ctrl_enter_for_newline` — multiline-only.  Pointless before
  multiline gets a DOM overlay; ships in turn 441 alongside
  that.
- Multiline polish (clip, scroll, copy-paste) — most of this
  comes free once multiline has a `<textarea>` overlay (turn
  441); the rest is `textEditor` arc work.

**Architectural decision codified this turn**: zimr will host
TWO text-editing primitives.

1. `inputText` (existing) + `inputTextMultiline` — form-flavor
   widgets.  Single-line form fields, comment boxes, search
   bars.  DOM overlay on web; wasm-side reference impl on host
   (for tests).  Browser owns cursor / IME / clipboard / soft
   keyboard.  P9 series finishes this primitive's flag parity.

2. `textEditor` (future, Tier 3) — renderer-side editor.  Code
   editors, Markdown editors, log viewers, REPLs.  ALWAYS uses
   wasm-side rendering — never the DOM overlay.  Required for
   any use case needing syntax highlighting, custom decorations,
   gutters, multi-cursor, custom keybindings, or scrolling huge
   buffers.  See §5b for the arc.

The split is per-widget, not per-device — mobile users of
`inputText` get DOM ergonomics; desktop users of `textEditor`
get full control.  Either widget runs on either device with the
expected tradeoffs.

**Tests**: +10-12 host-path tests (2 per flag).

### Turn 441 — Multiline P9.2 wiring + ctrl_enter_for_newline (host path) ✅

Host-path piece landed: `ctrl_enter_for_newline` opts field
with full behavior table; `enter_returns_true`,
`escape_clears`, `read_only`, and `commit_pressed` tracking
wired into `inputTextMultilineImpl` matching what
`inputTextImpl` got in turn 440.  +5 tests.

DOM `<textarea>` overlay split off to turn 441b — see below.

### Turn 441b — Multiline `<textarea>` DOM overlay ✅

10 new JS bindings (5 lifecycle + 4 P9.2 attribute setters +
ctrl_enter_for_newline).  `ensureOverlayTextarea` mirrors
`ensureOverlayInput` with the textarea-specific Enter
semantics (default Enter inserts \n; flag-on commits with
Ctrl+Enter inserting).  `inputTextMultilineImpl` web path
now polls the DOM textarea each frame, host path runs the
edit loop unchanged.  Phone example extended with 3 multiline
cards.

Tech debt: ~150 LOC of overlay duplication in zimr.ts.
Future unification once a third overlay type appears.

### Turn 442 — P9.3 InputText callback contracts pinned + honest web-path docs ✅

The callback infrastructure was already shipped in earlier
turns (P9 base layer).  Turn 442 added:
- 8 tests pinning down `edit` / `completion` / `history` /
  `char_filter` contracts (when each fires, when each
  doesn't, what `data` payload looks like).
- Honest per-callback "Web-path note" paragraphs on each
  `InputTextOpts` field doc.  Summary: only `edit` works on
  web today (DOM length-change polling triggers it the same
  way as host); the others depend on wasm-side keyboard
  events the DOM input/textarea overlay swallows.  Web
  parity for the host-only three deferred — easy to add when
  a real product needs them.

Phone example `ui_notes_phone.zig` (Q8 auto-save scratchpad)
split to turn 442b — keeps each turn focused.

### Turn 442b — `ui_notes_phone.zig`: scratchpad with Q8 auto-save ✅

Integration demo composing turn 423 (Q8 persistence) + turn
441b (textarea overlay) + turn 442 (edit callback) into one
mobile-first use case.  ~140 LOC in
`examples/ui_notes_phone.zig`.  Notes persist across page
reloads via localStorage on web.

### Turn 443 — P10.1 ColorEdit display format ✅

`ColorEditDisplayFormat` enum (`.float`, `.int_0_255`, `.hex`)
+ wire into `colorEditNFloat` rendering.  Format helpers
`colorChannelToInt255` and `formatColorRgbHex` shipped as
pure fns (testable in isolation).  +7 tests.

The "picker variant" half of the original plan note already
existed as `ColorPickerLayout` (`.bar` / `.wheel`).  RGB/HSV
picker variants deferred to a later P10 sub-turn since the
picker has its own rendering loop.

### Turn 444 — P10.2 ColorEdit suppression flags

`no_alpha`, `no_drag_drop`, `no_options`, `no_picker`,
`no_inputs`, `no_tooltip`, `no_label`, `no_side_preview`,
`no_small_preview`.  +9 tests.

### Turn 445 — P10.3 ColorEdit alpha + HDR flags

`alpha_bar`, `alpha_preview_half`, `alpha_preview`, `hdr`,
`float`, `display_rgb/hsv/hex`, `uint8`, `picker_hue_bar/wheel`.
+8 tests.

### Turn 446 — P10.4 Color converter methods

`u.colorConvertRgbToHsv(rgb) → hsv`, `u.colorConvertHsvToRgb(hsv) → rgb`,
`u.colorConvertU32ToFloat4(u32) → Color4`,
`u.colorConvertFloat4ToU32(c) → u32`.  Tiny module-level fns.
+8 tests.

**Phone example**: `ui_color_studio_phone.zig` — hue ring +
complement/triad palette generator.

### Turn 447 — P11 Selectable callback redesign

Selectable callback opts (selected, just_clicked, double_clicked,
drag_into).  Scoped down from v6 plan.  +6 tests.

### Turn 448 — P12.1 Drag/Slider range-in-opts audit

Consistency pass.  Every drag/slider takes `min: T, max: T` in
opts (no `*min`, `*max` ptr args left over).  +4 tests.

### Turn 449 — P12.2 DragN / SliderN

`drag2`, `drag3`, `drag4`, `slider2`, `slider3`, `slider4`,
plus `dragInt2/3/4`, `sliderInt2/3/4`.  Comptime-generated
via `inline for (.{2, 3, 4})`.  +12 tests.

**Desktop example**: `ui_color_mixer_desktop.zig` — RGB/HSV/alpha
linked sliders (sets up for turn 450 Bind(T) introduction).

### Turn 450 — `Bind(T)` reactive binding type

`pub fn Bind(comptime T: type) type` returns a struct
`{value: *T, on_change: ?*const fn(new: T) void = null}`.  Every
drag/slider/input gains an `?Bind(T)` opt that supplants the
`&value` arg when set.  Backwards compat: existing direct ptr
still works.  +6 tests.

### Turn 451 — P13.1 MultiSelect nested scopes

Multi-select inside another, shift-click ranges respect scope
boundaries.  +8 tests.

### Turn 452 — P13.2 MultiSelect shift-click range + ctrl-click toggle

Range selection with shift, toggle with ctrl.  +6 tests.

**Phone example**: `ui_file_picker_phone.zig` — folder
navigator with multiselect for batch ops.

### Turn 453 — P14.1 Logging family (capture to clipboard / TTY)

`u.logToClipboard()`, `u.logToFile(path)`, `u.logToTty()`,
`u.logFinish()`, `u.logText(s)`.  Captures rendered output as
text.  +6 tests.

**Imgui ref**: `imgui.h:865-885` LogToClipboard/File/TTY.

### Turn 454 — P14.2 log auto-format

Bullet text auto-prefixed with `*`, tree node depth auto-indented
in log output.  +4 tests.

### Turn 455 — P15.1 showDemoWindow (the showcase)

`u.showDemoWindow(open: ?*bool)` — the big monolithic demo with
every widget.  Migrates `examples/ui_full_showcase.zig` to be a
thin wrapper that just calls `u.showDemoWindow(&state.open)`.
+3 tests.

### Turn 456 — P15.2 showMetricsWindow (frame metrics)

`u.showMetricsWindow(open: ?*bool)` — DebugLog ring viewer, frame
metrics, draw cmd counts, window list, dock-tree dump, hovered/
active id, input snapshot summary.  +4 tests.

### Turn 457 — P15.3 showStyleEditor (interactive)

`u.showStyleEditor()` — interactive editor for every Style field.
Save current as `dark_default` / `light_default` / `classic_default`.
Diff-from-default view.  +4 tests.

### Turn 458 — P15.4 showAboutWindow + showIDStackTool

`u.showAboutWindow(open)` — version, build info, contributors.
`u.showIdStackTool(open)` — hover any widget to see its full id-
stack path.  Useful for debugging hash collisions.  +4 tests.

### Turn 459 — P16.1 KeyboardKey expansion audit (now lightweight thanks to Q1)

Now that Q1 ships the key-state array, this is just **audit
existing widgets** to use `u.isKeyPressed(.X)` instead of
direct `ctx.input.X` access.  ~20 sites.  +6 tests.

Net code SHRINKS — the audit replaces ~80 LOC of hardcoded field
access with array-indexed calls.

### Turn 460 — P16.2 popup variants

`beginPopupContextWindow`, `beginPopupContextVoid`,
`openPopupOnItemClick`, more popup flag combinations.  +8 tests.

### Turn 461 — P16.3 checkboxFlags + radioButtonInt

`u.checkboxFlags(label, flags: *FlagStruct, mask: FlagStruct)` —
toggles a bit-flag set.  Comptime-generated via field iteration.
Plus `u.radioButtonInt(label, value: *i32, button_value: i32)`
for the imgui-canonical radio-by-int-value pattern.  +6 tests.

### Turn 462 — P17.1 format-string + args validation (comptime)

Comptime check that `u.text("{d}", .{42})` matches arg count +
types.  Uses Zig's `std.fmt.comptimePrint` machinery.  Failures
become compile errors with location info.  +6 comptime-tests.

**Imgui can't do this** — C++ varargs throw the type info away.
Zig comptime makes it free.

### Turn 463 — P17.2 range checks + P17.3 drag-drop audit

Comptime check `slider(label, &v, .{.min = 5, .max = 3})` errors
(`min > max`).  Comptime audit that every `dragDropSource` has
a matching `dragDropTarget` register (where statically resolvable).
+8 comptime-tests.

### Turn 464 — Tier 2 review + arc-close changelog draft

Final imgui parity audit.  Update CHEATSHEET, update
`imgui-plan-v7.md` (mark every P ✅).  Write the changelog
section that says "imgui parity arc closed at turn 459."

Tests at this point: ~1 970 (from 1 687 + 283 across Tier 1 + 2).

---

## 4. Tier 3 — Secondary primitives + adaptive layout (turns 459–473)

15 turns for the non-imgui-parity architectural seeds that aren't
already in Tier 1.  These polish zimr's "successor to imgui" story
ahead of the implot port.

### Turn 465 — `u.adaptive(.{narrow, wide}, body_fn)` adaptive layout

```zig
u.adaptive(.{
    .narrow = struct { fn body(u: Ui) void { ... vertical stack ... } }.body,
    .wide   = struct { fn body(u: Ui) void { ... horizontal row ... } }.body,
});
```
Picks based on `ctx.viewport().is_phone`.  Comptime-checked
function shapes.  +4 tests.

**Imgui has nothing for this.**  zimr's phone story makes it
worth shipping.

### Turn 466 — Gesture model expansion: swipe + pinch

`u.onSwipe(.{.direction = .left, .min_distance = 50})` returns
`bool` (fired this frame).  `u.onPinch(.{}) → ?f32` returns scale
delta when active.  Built on the existing long-press → right-
click machinery.  +6 tests.

### Turn 467 — Touch-target lint rule + a11y groundwork

Lint rule: any clickable widget (button/checkbox/etc.) whose
final rect is < 44pt × 44pt at the current font size emits a
warning.  Suppressible via `opts.touch_target_check = .skip`.
+4 tests, +1 lint rule.

A11y groundwork: every Ui widget gains an optional
`aria_label: ?[]const u8 = null` opt field.  Today it's just
stored on the context for debugging; future browser backend will
wire it to DOM overlay nodes.  Comptime-checked existence per
widget type.  +0 tests this turn (it's just plumbing).

### Turn 468 — State-as-data: `u.queryState(T, label) → ?*const T`

Public read-only access to internal widget state.  Powers
diagnostics, test introspection, future undo/redo.  +6 tests.

### Turn 469 — Virtual scrolling (CalcListClipping)

`u.beginListClipper(item_count, line_height) → ClipperState` +
`while (clipper.step()) |range| { ... }` — only iterate the
visible item range.  Imgui's `ImGuiListClipper` equivalent.
+6 tests.

### Turn 470 — Markdown rendering primitive (`u.markdown(text)`)

Simple markdown renderer in zimr — `**bold**`, `_italic_`,
`#`/`##` headings, `-` bullets, `[link](url)`, code spans.
Built on existing textWrapped + textColored + style guard.
No external lib.  Reuses Q7 arc primitive for the `>` blockquote
indicator.  +8 tests.

**Extension precursor**: this is what `imgui_markdown` /
`imgui_md` do as extensions; we ship a minimal one in-tree.

### Turn 471 — Toast notifications (`u.notify(...)`)

`u.notify(.{.kind = .info, .title = "Saved", .body = "...", .duration_s = 3})` — slides in from top-right, animates via Q9
spring, dismisses after duration.  Stack of up to 5 simultaneous.
+8 tests.

**Phone example**: `ui_toast_demo_phone.zig` — tap to fire a
toast.

### Turn 472 — Hotkey + command palette infrastructure

`u.registerHotkey(.{key, mods, label}, callback)` builds a
context-frame hotkey registry.  `u.commandPalette()` opens
ctrl-shift-P-style modal listing every registered hotkey, with
fuzzy filter (reuse TextFilter).  +8 tests.

**Imgui equivalent extension**: `imgui-command-palette`.  We ship
in-tree.

### Turn 473 — Date picker primitive (`u.datePicker(value: *Date)`)

Compact month grid with year+month nav, selectable cells via
existing selectable infra.  ~200 LOC.  +6 tests.

**Phone example**: `ui_birthday_picker_phone.zig` — picks a date
on phone.

### Turn 474 — File browser primitive (`u.fileBrowser(opts) → ?Path`)

Compact in-window file browser using runtime FS bridge.  Sort,
filter, multi-select via P13.  Persistable last-folder via Q8.
~400 LOC.  +10 tests.

### Turn 475 — Tree node connector lines (TreeNodeDrawLines wiring)

The TODO on `TreeNodeOpts.draw_lines` from turn 412.  Now wireable
because Q4 canvas + Q7 arcs make it natural.  +4 tests.

### Turn 476 — Knob widget (`u.knob(label, value: *f32, opts)`)

Built on Q3 single-call ItemCtx + Q7 arc + Q9 animation for
release-snap.  Custom widget reference impl ships in-tree.
+6 tests.

**Phone example**: `ui_synth_phone.zig` — 4 knobs for an
audio synth, plays via existing audio bridge.

### Turn 477 — Spinner widget (`u.spinner(label, opts)`)

Built on Q7 arc + Q9 spring.  Multiple visual styles
(circle, dual-ring, bar).  ~150 LOC.  +4 tests.

**Equivalent extension**: `imspinner` — we ship a curated
subset.

### Turn 478 — Toggle switch (`u.toggle(label, value: *bool)`)

iOS-style sliding switch.  Built on Q9 spring (the slider knob
springs to its target side).  +4 tests.

### Turn 479 — Tier 3 review

Audit secondary primitives, update CHEATSHEET.

Tests at this point: ~2 055.

---

## 4b. The `textEditor` arc — renderer-side text editing (turns TBD, sized at scheduling time)

**Decision (turn 440):** zimr will host two text-editing
primitives, not one.

- `inputText` / `inputTextMultiline` are FORM-FLAVOR widgets.
  They use the DOM overlay on web for native-browser editing
  ergonomics (soft keyboard, IME, clipboard, scroll-into-view-
  above-keyboard).  Host path is the reference for tests.
  Right for: form fields, search bars, comment boxes, simple
  multiline notes.

- `textEditor` (this arc) is the RENDERER-SIDE text editor.
  Wasm owns the entire edit pipeline.  Never touches the DOM
  overlay.  Required for: syntax highlighting, gutters / line
  numbers, custom decorations (squiggles, inlay hints), multi-
  cursor, custom keybindings, scrolling huge buffers, anything
  needing pixel control over how characters render.

The split is per-widget, not per-device.  Mobile users of
`inputText` still get the soft-keyboard experience; desktop
users of `textEditor` get a real editor.  Either widget works
on either device, with the expected tradeoffs.

**Why a new arc, not a Tier 3 turn**: the editor needs a real
edit engine — buffer + cursor + selection + line-col tracking +
mouse-hit-to-cursor + word boundaries + scroll + custom render
+ syntax highlighting hooks + caret blink + clipboard
primitive.  None of that ships incrementally in one turn; it's
a 5-10 turn arc.

**Arc shape (to be sized + scheduled at planning time)**:

1. Edit engine — gap buffer + cursor + line index.
2. Selection model — primary range, multi-cursor opt-in later.
3. Mouse → cursor — click positions caret, drag selects.
4. Render — laid-out lines, caret blink, selection rect, scroll.
5. Keybindings — arrow / home / end / page / cmd-arrow / etc.,
   pluggable for caller overrides.
6. Syntax-highlighting API — caller supplies a `Tokens` stream
   per visible line; renderer applies colors.
7. Gutter API — caller draws into a gutter strip on the left.
8. Search / replace primitives.
9. Clipboard integration (web: `navigator.clipboard`; host:
   stub or a minimal in-memory clipboard).

**When**: scheduled at the next Tier-3 review (turn 479) once
we see how many open Tier-3 commitments there are and how the
plot port is shaping up.  Likely scheduled BETWEEN Tier 3 close
and Tier 4 plot port, OR after Tier 4 — depends on user need.
No code dependencies in either direction.

**§13 anchor**: this section is the placeholder; the arc will
land as a new top-level section §4c (or similar) when scheduled.

---

## 5. Tier 4 — Implot D-expanded port (turns 474–498)

25 turns for the full implot subsystem inside ui.zig.  Built on
every prior pillar.  No new architectural decisions needed;
this is execution.

**Order**: lifecycle + setup + coord conversion first (so per-
plot wiring works), then plot items in waves by complexity, then
drag-drop + subplots last.  Examples interleaved.

### Turn 480 — Plot lifecycle (`beginPlot`, `endPlot`, plot context)

```zig
const PlotCtx = struct {
    id: Id,
    rect: Rectangle,           // outer plot rect including axes
    plot_rect: Rectangle,      // inner plot area (axes drawn around)
    canvas: CanvasCtx,         // <-- a plot IS a canvas (Q4)
    axes: [4]AxisState,        // x1, y1, x2, y2 — implot supports 4 axes
    items: BoundedArray(PlotItem, MAX_ITEMS_PER_PLOT),
    legend_rect: ?Rectangle,
    hovered: bool,
    held_item: ?Id,
};

pub fn beginPlot(self: Ui, title: []const u8, opts: PlotOpts) ?PlotCtx { ... }
pub fn endPlot(self: Ui, pc: PlotCtx) void { ... }  // <-- type-state forces pairing
```

`PlotCtx` not in caller scope means `endPlot` can't be called —
compile error.  Same defer-RAII safety as Q5 styleOverride.

**Tests** (8): begin returns null when clipped, plot_rect inside
rect, canvas hooked up correctly, axes default to auto-fit on
first frame, end is mandatory (test-side check that forgetting
end doesn't crash but emits a lint warning).

### Turn 481 — Plot setup family (axes + axis + axis_format)

`plotAxes(x_label, y_label, x_opts, y_opts)`,
`plotAxis(axis: PlotAxis, label, opts)`,
`plotAxisFormat(axis, comptime fmt: []const u8)`,
`plotAxisFormat(axis, fmt_fn: *const fn(...))`.

**Tests** (8): axes set labels, axis flags set per-axis, format fn
called per tick, comptime format string validated.

### Turn 482 — Plot setup family (limits + ticks + scale)

`plotAxisLimits(axis, min, max, cond)`,
`plotAxisTicks(axis, positions, labels)`,
`plotAxisScale(axis, scale: .linear | .log10 | .symlog | .time)`,
`plotAxesLimits(xmin, xmax, ymin, ymax, cond)`.

**Tests** (10): limits set + clamp on draw, ticks override
default, log scale renders correctly, time scale formats as
date.

### Turn 483 — Plot setup family (legend + mouse_text + finish)

`plotLegend(location, flags)`,
`plotMouseText(location, flags)`,
`setupFinish()` (called automatically at first plot item;
explicit version available for advanced).

**Tests** (6): legend appears at requested corner, click toggles
item visibility, mouse_text shows cursor coords.

### Turn 484 — Plot coordinate conversion

`plotToPixels(pc, data_pt) → Vec2`,
`pixelsToPlot(pc, pixel_pt) → Vec2`,
plus 1D variants per-axis.

Coord conversion uses the canvas transform stack from Q4.
"Apply the data → screen mapping" is just a transform push at
plot start.

**Tests** (6): round-trip plotToPixels → pixelsToPlot is identity,
zoom/pan via axis limits affects mapping, log-scale mapping non-
linear.

### Turn 485 — Plot item wave 1: Line + Scatter

`plotLine(label, xs, ys, count, opts: PlotItemOpts)`,
`plotScatter(label, xs, ys, count, opts)`.  Comptime generic over
element type (`f32`, `f64`, `i32`).

```zig
pub fn plotLine(
    self: Ui,
    label: []const u8,
    xs: anytype, ys: anytype,  // []const f32 / f64 / i32 etc.
    opts: PlotItemOpts,
) void {
    const T = @TypeOf(xs);
    comptime { /* validate T is a slice of numeric */ }
    ...
}
```

PlotItem registered in the current plot's item list (via Q2 state
storage on the plot's id), drawn on endPlot.

**Imgui ref**: `implot.h:989-991` PlotLine.

**Tests** (10): 100k-point line renders without dropping, segments
flag joins separate lines, line + marker, line color from auto-
palette when not specified, multiple lines get distinct palette
colors.

**Desktop example**: `examples/ui_plot_lines_demo.zig` — multi-
line sin/cos demo from implot's demo.cpp ported.

### Turn 486 — Plot item wave 1 cont: Bars

`plotBars(label, xs, ys, count, opts)`,
`plotBarsHorizontal(label, xs, ys, count, opts)` (or via
`opts.horizontal = true`).  +8 tests.

### Turn 487 — Plot item wave 2: BarGroups + Stairs

`plotBarGroups(labels, values, group_count, item_count, opts)`,
`plotStairs(label, xs, ys, count, opts)`.

BarGroups is the "side-by-side multi-series bars" use case
(monthly sales by region etc).  +10 tests.

### Turn 488 — Plot item wave 2 cont: Shaded + Polygon

`plotShaded(label, xs, ys_lo, ys_hi, count, opts)` — fill between
two y-arrays.  `plotPolygon(label, xs, ys, count, opts)` — filled
closed polygon.  Uses Q7 addPolygon.  +8 tests.

### Turn 489 — Plot item wave 3: ErrorBars + InfLines + Stems

`plotErrorBars(label, xs, ys, neg, pos, count, opts)`,
`plotInfLines(label, values, count, axis, opts)` — vertical or
horizontal infinite lines (thresholds, reference lines),
`plotStems(label, xs, ys, count, opts)` — line-from-axis + marker.
+12 tests.

### Turn 490 — Plot item wave 4: PieChart

`plotPieChart(labels, values, count, x, y, radius, opts)`.
Uses Q7 addArcFilled for each slice.  Auto-label placement at
slice centroid.  +8 tests.

**Desktop example**: `examples/ui_plot_piechart_demo.zig`.

### Turn 491 — Plot item wave 4 cont: Heatmap

`plotHeatmap(label, values, rows, cols, scale_min, scale_max,
opts)`.  Colormap (from auto-palette interpolation).  +8 tests.

### Turn 492 — Plot item wave 4 cont: Histogram

`plotHistogram(label, values, count, opts.bin_count or bin_size)`.
Auto-binning via `count.sqrt()` if bins not specified
(Sturges' rule).  +8 tests.

### Turn 493 — Plot item wave 5: Image + Text + Rect

`plotImage(label, texture_id, p_min, p_max, uv_min, uv_max, opts)` — overlay a texture on the plot at data coords.
`plotText(label, x, y, opts)` — annotation at data coords.
`plotRect(label, p_min, p_max, opts)` — rectangle annotation.
+12 tests.

### Turn 494 — Plot drag-drop integration (consolidated entry point)

`plotDragDropSource(opts) → ?DragDropPayload` — single entry,
hit-tests against items / axis / legend / plot-body and dispatches.
`plotDragDropTarget(opts) → ?DragDropPayload` — same.
Internally uses the existing P11-era drag-drop infra.  +8 tests.

### Turn 495 — Subplots (composition)

`beginSubplots(title, rows, cols, size, opts) → ?SubplotCtx`,
`endSubplots(sc)`.  Each subplot is a `beginPlot/endPlot` pair;
subplots coordinate axis linking (zoom one, all zoom) via shared
axis state.  +10 tests.

### Turn 496 — Auto-palette + plot Style fields

The one opinionated colormap: ~12 distinct hues, picked from a
perceptually-uniform palette (Tab10 or similar).  Stored as
`style.plot_palette: [12]Color`.  Plot items without `.line_color`
set get assigned by call-order within a plot.

Plus new Style fields: `plot_bg`, `plot_frame_bg`, `axis_text`,
`axis_grid`, `axis_tick`, `legend_bg`, `legend_border`,
`plot_border`, `plot_selection`, `plot_crosshairs`.  All default
to derivations of existing colors.  +6 tests.

### Turn 497 — Plot persistence (Q8 integration)

Plot state — axis limits when zoomed, legend item visibility — opts
into Q8 persistence via the plot's id.  Restored on next session.
+6 tests.

### Turn 498 — Plot interaction: zoom + pan + reset

Mouse wheel = zoom around cursor (clamps to axis limits).  Middle-
drag = pan.  Double-click = reset to auto-fit.  Box-select with
drag (`SetupBoxSelect` style).  Uses Q9 spring for smooth zoom
transitions.  +10 tests.

### Turn 499 — Plot keyboard navigation

Tab to focus plot.  Arrow keys = pan.  Ctrl+arrow = zoom.  R =
reset.  L = toggle legend.  Uses Q1 input layer + want_capture
flags.  +8 tests.

### Turn 497 — Plot show* demos (port implot_demo.cpp)

`examples/ui_plot_showcase.zig` — port `implot_demo.cpp` chunks:
LinePlots, FillingPlots, Bars, BarGroups, ErrorBars, etc.  ~20
tabs.  Each tab demonstrates one or two plot types.  Doubles as
the "did we port correctly" smoke test.

### Turn 501 — Plot demos: dashboard + real data

`examples/ui_dashboard_phone.zig` — phone-friendly metric tiles
with sparkline plots (plotLine in small rects).
`examples/ui_stock_chart_desktop.zig` — candlestick-style chart
using plotShaded + plotInfLines.

### Turn 499 — Plot edge cases + accessibility audit

NaN handling in input data, empty input arrays, single-point
plots, negative-axis-range, zero-range axis.  Plus a11y audit:
every plot item gets an `aria_label` slot.  +12 tests.

### Turn 500 — Plot lint rules

3 new lint rules:
- Plot items registered without enclosing beginPlot
- endPlot called without matching beginPlot
- Plot drawn with > 1M points (perf warning, suppressible)

+6 tests.

### Turn 501 — Tier 4 review + plot completeness audit

Compare zimr's plot surface to implot's actual demo.cpp examples
one-by-one.  Document the "I can port my implot code" promise:
which patterns just work, which need minor edits, which are
deliberately out of scope.  Update CHEATSHEET (`PLOTS.md`
section added).

`src/notes/tier4-implot-port-review.md` (~8KB) — public API
table comparing implot:zimr per fn, gap list, porting guide.

Tests at this point: ~2 200.

---

## 6. Tier 5 — Capstone + polish (turns 498–511)

15 turns for the arc-close work.  Examples, audit, archive.

### Turn 501–500 — Phone + desktop example explosion

5 turns, 2 examples per turn = 10 new examples leveraging
everything that landed:

- `ui_calculator_phone.zig` (turn 497)
- `ui_habit_tracker_phone.zig` (turn 497)
- `ui_stopwatch_phone.zig` (turn 501)
- `ui_audio_synth_desktop.zig` (turn 501, uses knob+plotLine waveforms)
- `ui_markdown_preview_desktop.zig` (turn 499)
- `ui_json_explorer_desktop.zig` (turn 499)
- `ui_pixel_paint_desktop.zig` (turn 500)
- `ui_spreadsheet_mini_desktop.zig` (turn 500)
- `ui_shader_preview_desktop.zig` (turn 501, uses plotImage + sliders)
- `ui_log_viewer_desktop.zig` (turn 501, uses listClipper + filter)

### Turn 503 — Comptime self-tests

Add ~30 comptime checks that the public API is internally
consistent: every `Opts` struct has a default, every fn taking a
label string takes a `[]const u8` (not `[*:0]const u8`), every
fn-with-callback opts groups callbacks together (not scattered),
naming consistency (`*Impl` removed where possible).

### Turn 504 — Performance pass

Measure: frame time @ 60fps with `ui_full_showcase` open
(stress test).  Optimize the top 3 hot paths.  Target: < 1 ms
ui work per frame on a mid-range desktop.

### Turn 505 — Docs sweep

Every public fn has a doc comment.  Every Opts struct documents
each field with a one-liner.  Cross-references where helpful
("see also `u.plotLine`").  Cheatsheet finalized.

### Turn 506 — Plan archive

`imgui-plan-v7.md` → marked ✅ closed at turn 458, archived to
`src/notes/archive/imgui-plan-v7-closed.md`.  Implot port plan
(this doc) → marked ✅ closed at turn 498, archived.

### Turn 508 — Lint rule audit

Verify all 18 lint rules (10 original + 4 from P17 + 1 from Q3
touch-target + 3 from plot) are correct, suppressible, well-
documented.

### Turn 509 — Schema version audit

Every Q8-persistable type's schema documented.  Migration policy
written for future schema bumps.

### Turn 510 — Test suite trim

Identify slow/flaky tests, fix or remove.  Target: full `zig
build test` in < 3 seconds.  Currently ~5-7s.

### Turn 511 — Arc-close changelog

`src/notes/changelogs/changelog500-509.md` — comprehensive
narrative of the imgui+implot port arc.  Headline numbers, what
shipped, what's next.

### Turn 511 — The next plan

Write `src/notes/the-next-arc-turn-511.md` — what we do AFTER
the imgui+implot arc closes.  Candidates: text editor (Q3-style
custom widget), node editor (canvas-based), hot reload polish,
WebGL2 → WebGPU migration, Wayland desktop backend.  Brainstorm,
don't commit.

---

## 7. Per-turn drill-down

The drill-down for turns 415–428 (full Tier 1) is generated
per-turn during execution, written into the changelog body
and into a turn-prep note at the start of each turn.  Pre-
generating drill-down for all 96 turns is wasted work — by the
time we reach turn 463, the early-turn experience will have
informed how we write later turn plans.

At each tier review checkpoint (turns 428 / 458 / 472 / 497 /
511), the next 15–20 turns get a fresh drill-down section
written into this document, replacing this placeholder.

Drill-down template per turn (followed in changelogs):

```
### Turn N — short title

**Goal**: 1-line goal.

**Imgui/implot source ref**: file:LINE ranges read before
implementing.  (Per execution rule 1.)

**Files touched**:
- src/ui.zig (specific ranges + summary of change)
- examples/X.zig (new or modified, LOC count)
- src/tests.zig (test discovery change if any)

**Tests added** (N):
- per-test one-line description

**Risk**: low/medium/high + 1-line rationale.

**Standalone build**: `python3 scripts/build_standalone.py X`
(only if a phone example shipped — output URL noted).

**Continuation note** (if 80%-budget cap hit): what's left,
where to pick up.
```

## 8. Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| 🟧 Q1 input rebuild breaks 12-15 existing sites | Medium | Test suite catches it; pure mechanical refactor |
| 🟧 Q2/Q8 schema-version mismatch in real-world reload | Medium | `ignore_unknown_fields = true` policy + per-version round-trip tests |
| 🟧 Q4 canvas transform stack has subtle math bugs | Medium | Reuse splitter (P7.2) channel pattern; transform is just a matrix mul at merge time |
| 🟨 Implot port discovers a missing pillar at turn ~480 | Low-Medium | Tier 1 review at turn 431 surfaces gaps early |
| 🟨 Bind(T) reactive type interferes with existing direct-ptr API | Low | Pure additive opts field; existing `&value` continues to work |
| 🟨 Comptime auto-serialize (Q8) hits a type it can't handle | Low | Clear compile-time error + manual override path |
| 🟧 Plot animations (Q9 zoom transitions) feel laggy at high item counts | Medium | Skip animation if item count > threshold; ship as opt-out flag |
| 🟧 50-100 turn estimate ±15% accuracy | Medium | Checkpoint reviews catch drift; defer/cut work at Tier review boundaries |
| 🟨 Cheatsheet bit-rot during heavy churn | Low | Auto-regenerate on every public-API turn; lint that new pub fns appear in cheatsheet |
| 🟧 Examples accumulate maintenance burden | Medium | Phone examples don't add unit tests; only one capstone (turn 495) gates other arcs |

---

## 9. What we explicitly do NOT do in this arc

- **No retained-mode pivot**.  Immediate mode stays.
- **No VDOM**.  No reconciliation.
- **No CSS / DOM layout**.  zimr stays a custom renderer with its
  own model.
- **No multi-viewport**.  Out of scope (would be a different arc).
- **No WebGPU migration**.  Stays on WebGL2.
- **No theme engine** beyond style fields + the 3 presets we
  ship + per-extension overrides via Q5.  No CSS-in-Zig.
- **No advanced text rendering**.  No RTL, no complex shaping.
  Latin + emoji is the floor.
- **No async loading primitives**.  Textures, fonts, file lists
  load synchronously.  Async is a future concern.
- **No accessibility runtime beyond `aria_label` slot**.  Wiring
  the slot to browser DOM overlay nodes is a future turn (not in
  this arc).
- **No comptime layout DSL**.  Mentioned in turn 414 brainstorm;
  deferred to a post-arc plan.

---

## 10. Cadence + checkpoint reviews

| Checkpoint | Turn | Purpose |
|---|---|---|
| Tier 1 review | 428 | Pillars audit; delta doc |
| Tier 2 review | 463 | Imgui parity audit; plan-v7 closeout |
| Tier 3 review | 472 | Secondary primitives audit |
| Tier 4 review | 497 | Implot completeness; porting guide |
| Final review | 511 | Arc close; next-plan doc |

At each checkpoint:
- Cheatsheet refreshed
- Lint rule audit
- Schema version audit
- Test budget check (are we on track for ~2 200 by close?)
- Risk register reviewed (any new risks?  any retired?)
- Re-plan if any tier exceeded ±20% of estimate

Per-turn:
- Changelog entry mandatory (header + rationale + files touched)
- Plan doc gets 1-line ✅ tag for the finished turn
- Zip saved (prune cadence: multiples of 5 + 5 most recent)
- `zig build test --summary all` zero failures
- `zig build lint-check` zero issues
- `python3 scripts/build_standalone.py <focus>` smoke test

---

## 11. Notes on ziggy patterns to lean into

### 11.1  `inline for` over fields

Used in Q1 (key loop), Q5 (style fields), Q8 (auto-serialize),
P12.2 (DragN/SliderN), P17 (comptime validators).  Zero-cost,
explicit, transparent.

### 11.2  `comptime T` everywhere

Q2 storage, Q9 anim slots, plot item registration, validators.
Zero runtime dispatch, type-checked at compile.

### 11.3  `union(enum)` for plot items

```zig
pub const PlotItem = union(enum) {
    line: PlotLineData,
    bars: PlotBarsData,
    scatter: PlotScatterData,
    ...,
};
```
One storage, one iteration loop, one switch.  All allocation in
a `BoundedArray(PlotItem, 64)` per plot — no heap.

### 11.4  Type-state for `Begin/End`

```zig
pub fn beginPlot(self: Ui, ...) ?PlotCtx { ... }
pub fn endPlot(self: Ui, pc: PlotCtx) void { ... }
                                       ^^^^^
//                            forced pass: you can't endPlot without
//                            having a PlotCtx returned by beginPlot
```
Misuse → compile error.  Already used in Q4, Q5.  Scale to plot,
subplot, canvas everywhere.

### 11.5  `?T` opt fields default to nil

Already idiomatic.  Continue.  Every Opts struct, every Q5
PartialStyle field, every Bind(T) wire.

### 11.6  `defer guard.restore()`

Q5's pattern.  Mirror for any scoped state in the future.

### 11.7  `BoundedArray(T, N)` over `ArrayList`

Per-frame transient state (plot items, anim slots, drag-drop
payloads).  Avoid heap allocation in the hot path; capacities
sized for "more than anyone needs."

### 11.8  Comptime validators

P17 ships them for format strings + ranges + drag-drop pairing.
Pattern: `comptime { ValidateFormat(fmt, @TypeOf(args)); }` at
the top of every fmt-taking function.  Errors propagate to the
call site.

### 11.9  Module-level `pub const X: T = ...` over enum-of-one

Already a principle in zimr.  Continue.

### 11.10  `errdefer` for partial-construction safety

Q4 canvas init, Q9 anim slot init, Q8 persistence load.
Cleanup-on-error without bookkeeping.

---

## 12. What success looks like at turn 507

- ✅ Every P-phase in imgui-plan-v7 closed
- ✅ Implot D-expanded port shippable; `examples/ui_plot_showcase.zig`
  visually demos every plot type
- ✅ ~40 examples covering phone + desktop
- ✅ ~2 270 tests passing, zero lint issues, single flat ui.zig
  of ~55 KLOC
- ✅ Cheatsheet documents every public symbol
- ✅ Porting guide for "I have implot code, how do I port to
  zimr" written
- ✅ The 9 architectural pillars (Q1–Q9) are load-bearing across
  the codebase, not theoretical
- ✅ No `@This()` aliases, no module-qualifier indirection, no
  unnecessary abstractions
- ✅ `next-arc` doc written, candidate features listed

Then we ship a real thing built on it.

---

## 13. Backlog — improvements waiting for a real trigger

This list holds work that's specifically blocked on a future
event: a real use case appearing, a confirmed profile result, or
a related design landing.  Items here have a clear "do this when
X happens" trigger.  Items without a trigger — speculative
features, sketches, "would be nice" notes — don't belong here;
they either get done now or get deleted.

When a turn touches related code, scan this section for items
whose trigger has fired.

### Triggered on: a profiled performance issue

- **Native `arc` / `arc_filled` DrawCmd variants.**  Arcs
  currently emit through `polyline` (stroked) or N
  `triangle_filled` commands (filled).  If arc spam shows up in
  a profile, add dedicated variants routed through
  `drawing.shapes.drawRingFilled` (raylib has the primitive).
  Trigger: a profile shows arc command-emission cost.

### Triggered on: a feature surfaced by phone testing

- **Snapshot-test the data-grid example at multiple
  `scroll_x` values.**  The Tier 1 snapshot infrastructure
  (turn 430) was designed specifically to catch the class of
  bug turn 432 found in the field: "bookkeeping ships, but
  content doesn't visually shift."  No X-scroll snapshot test
  exists yet.  Trigger: next time someone touches the
  snapshot-test scenes — add three baseline PNGs of the data
  grid at scroll_x = 0, mid, and max.

- **Formalize touch-hit inflation as a `Ui` utility.**  Turn
  432 inflated the scrollbar hit-test rect by 22 px on the
  thin axis to satisfy touch-target minimums (Material 48,
  Apple 44).  The same pattern will repeat for slider grips,
  close-tab X buttons, resize-grip corners.  Don't ship the
  utility now — wait until a SECOND widget needs the same
  treatment, then lift the constant + direction logic into
  e.g. `inflateForTouch(rect, sides) Rectangle`.  Trigger:
  the second small clickable that fails a touch-target audit.

- **Lint rule for "code that touches `cursor_pos[0]` must
  consult `scroll_x`."**  The bug 2 root cause (turn 432) was
  three sites that recomputed cursor_pos[0] from origin
  without scroll subtraction.  A lint check could grep for
  `cursor_pos\[0\]\s*=` and warn if `scroll_x` isn't
  referenced in the surrounding ~5 lines.  Speculative; only
  build if a fourth site appears that violates the rule.
  Trigger: a future regression of the same shape.

- **Audit P9+ phases for flag-vs-feature ordering.**  Turns
  433 and 437 both shipped honest scopes ~half the plan's
  flag list because the plan assumed infrastructure that
  doesn't exist yet.  Before committing to a "+N flags +
  small example" turn, scan each flag and ask "does this
  flag suppress / extend something real, or something the
  plan assumed exists?"  Re-scope honestly upfront rather
  than at audit-time.  Trigger: every plan turn that lists
  "remaining flags" or "+N small additions."

### Triggered on: prerequisite table features landing

- **`TableColumnOpts.user_id` + `tableGetColumnUserId`.**  Imgui
  tags each column with a `ImGuiID UserID` field that sort
  callbacks can read instead of column-index switches.
  zimr's `TableColumnOpts` has no user_id slot today and
  `TableSortSpec.column_index` is the only column-identity
  channel into the sort comparator.  Adding it is a one-field
  extension to opts + one-field extension to column state +
  one getter — wait until a real callsite wants index-stable
  IDs across column reorder (which is itself a not-yet-landed
  feature, see `no_reorder` below).  Trigger: column reorder
  lands AND a use case for stable-id-vs-position-index appears.

- **`TableColumnOpts.no_resize`.**  Currently nothing to
  suppress — column widths are set by the sizing policy +
  user weight, never by drag.  When user-driven column resize
  (drag the right edge of a header cell) is added, this flag
  blocks it on a per-column basis.  Trigger: user-resize
  column header lands.

- **`TableColumnOpts.no_reorder`.**  Currently no
  drag-to-reorder.  When that lands (drag a header cell
  horizontally past a sibling to swap them), `no_reorder`
  pins that column in place.  Trigger: column reorder lands.

- **`TableColumnOpts.no_hide` and `default_hide`.**  No
  per-column visibility today.  Add when a context-menu
  "Hide column" feature lands.  `no_hide` removes the menu
  item; `default_hide` ships the column hidden by default
  (user must un-hide via the menu).  Trigger: hide-column
  context menu lands.

- **`TableColumnOpts.indent_enable` / `.indent_disable`.**
  No per-column indent system.  `indent_x` lives on the
  window's `LayoutScope` — there's no notion of indent
  applying to one cell of one row and not another.  Trigger:
  per-column indent (e.g. an "expandable tree" column type
  for tree-tables) lands.

- **`TableColumnOpts.no_clip`.**  No per-cell clip rect today
  — comment in `tableHeadersRowImpl` near line 21902 notes "no
  explicit per-cell clipping; for now the cell is wide enough
  in practice."  Flag-suppresses-nothing until cell-clip
  exists.  Trigger: cell-level clipping primitive lands (e.g.
  for ellipsis-truncated long text).

- **`TableColumnOpts.no_header_width`.**  `snapshotCellWidth`
  measures cell content only — header text doesn't push the
  cursor so doesn't contribute to `width_auto_seen`.  Flag
  has nothing to suppress today.  Trigger: a measurement
  path that includes header text width.

- **Angled column headers (P8.7 / `tableAngledHeaders`).**
  Needs a rotated-text draw primitive.  No `drawTextRotated`
  exists.  Roughly: per-glyph rotation matrix applied at
  quad emission, ~80 LOC in `drawing/text.zig` plus a new
  opt on the header row.  Until then, callers use
  `no_header_label = true` and roll their own header
  surface.  Trigger: a real surface needs narrow columns
  with long labels.

### Triggered on: a real use case appearing

- **List drag-reorder primitive** (kanban lanes, playlist
  tracks, todo priorities).  Turn 433 needed this to build a
  proper draggable-card kanban board but punted to a flat-table
  view instead.  Probably looks like `dragHandle(id, *index,
  list_len) bool` returning true on the frame the user dropped
  it in a new slot, with the widget itself rendering a grip
  icon.  Build it when a real surface (not just a contrived
  example) needs it.  Trigger: a second example or real product
  surface that needs reorderable lists.

- **Rotation in `CanvasTransform`.**  Today translate + per-axis
  scale only.  When a caller needs rotated content on a canvas
  (rotated text overlays, rotated sprites), add `rotation: f32`
  to `CanvasTransform` and extend `compose` / `inverse` /
  `applyLocal` — standard 2x2 matrix math, ~20 LOC.

- **Concave `addPolygon`.**  Fan-triangulates from `points[0]`
  today.  Concave polygons render with overlapping triangles —
  visually wrong.  When a caller actually needs concave shapes,
  swap in ear-clipping triangulation (~80 LOC, well-trodden).
  Doc comment already states convex-only.

- **Auto-size `beginCanvas` (size = `.{0, 0}` → fill remaining).**
  Imgui's `BeginChild` does this.  Useful for "canvas takes the
  rest of the window."  Add when an example needs it.

- **Nested canvases with independent transform stacks.**
  Today `canvas_transforms` lives on `UiContext`; one stack
  shared.  When a real caller wants two live canvases with
  independent pans/zooms, move the stack onto `CanvasCtx`.

- **`addRoundedRectMixed` per-corner radii.**  `addRectFilled`
  has uniform corner_radius only.  Add a `radii: [4]f32` variant
  when a real widget needs different per-corner roundings.

- **Canvas channels for z-ordered draws.**  Imgui's
  `ChannelsSplit` / `ChannelsMerge` lets callers author in
  natural order while controlling z.  Useful for node-editor
  "draw bodies after edges" — current node-editor example
  doesn't need it.  Add when one does.

- **`u.showMetricsWindow` consumes `z.todo` accumulator.**
  Today `z.todo` deduplicates by call site but doesn't keep a
  ledger.  When `showMetricsWindow` lands, give it a list of
  every stub the running app has hit.

### Triggered on: a planned feature landing

- **`Bind(T)` integration with extension state.**  Planned later
  in the roadmap.  When it ships, design the read/write
  bridging from extension state slots in one pass.

- **`Bound(T, .{ .min, .max })` comptime range type.**  Overlaps
  with planned slider range validation — design once when that
  lands, not twice.

### Reference-only (no code action, just don't repeat the mistake)

- **`Id` as a distinct enum.**  Tempting for type-safety
  (`enum(u32) { _ }`).  Cost: every Id literal needs
  `@enumFromInt(N)`.  The bug-prevention upside is moderate;
  the call-site churn across hundreds of sites is large.  If
  Zig ever gets cleaner distinct-integer syntax, reconsider.
  Don't open this without a reason.

- **`PartialStyle` literal autocomplete.**  Comptime-derived
  types don't surface field names in IDEs as well as
  hand-written structs.  Mitigation is documenting Style's
  fields in the `styleOverride` doc comment.  Don't materialize
  a hand-written PartialStyle — keeping it derived means new
  Style fields auto-propagate.

- **Don't migrate `tab_bar_state` / `combo_state` /
  `table_sort_state` / `table_scroll_state` /
  `table_width_auto_cache` to `ext_storage`.**  Evaluated and
  rejected: the 5 bespoke `AutoHashMapUnmanaged(Id, X)` fields
  on `UiContext` are typed end-to-end and have direct accessors
  (`ctx.tab_bar_state.getPtr(id)` etc).  Moving them through
  `getOrPutState` adds a comptime-key + void-pointer cast layer
  with no functional gain — none of them want persistence
  today.  Pure regularization without improvement.  If one of
  them later wants persistence, migrate JUST that one — the
  others can stay typed.

---

Items that were here previously and have been **done** or
**deleted** as obsolete:

- *Migrate built-in widgets to the primitives* — done across
  button / smallButton / arrowButton / checkbox / radio /
  selectable.
- *`putState` overwrite trap* — deleted; the API now exposes
  `getOrPutState` returning `{ value_ptr, found_existing }`,
  mirroring `std.HashMap.getOrPut`.  No two-call dance, no
  init-blasts-load.
- *`Color` / `Rectangle` reachability from extension authors* —
  done; both are re-exported at the top of `ui.zig`.
- *`Ui.fillRect` / `Ui.strokeRect` convenience methods* — done.
- *`DrawListHandle` missing primitives* — done; addArc,
  addArcFilled, addPolygon, addBezierCubic, addNgon,
  addNgonFilled, addEllipse, addEllipseFilled, addPolyline,
  addQuadFilled now forward through the handle.
- *Canvas `applyPoint` returning canvas-local was the wrong
  default name* — renamed to `applyLocal`; `toScreen` is the
  single sanctioned authoring→screen helper.
- *`itemAdd` canvas-aware clip* — wire when canvas grows
  callers that draw outside its rect; today the bounds-check
  through window suffices.
- *ADR-comment lint rule* — deleted; comments now must not
  reference plan steps or history at all.  See claude.md rule 4.
- *Carmack audit on hardcoded input-key reads* — deleted;
  blanket-rule lint is unfocused.  Address case by case when
  touching a widget that reads keys directly.
- *Wasm32 smoke-test for every Q-pillar* — promoted to a
  per-turn rule in §1 / claude.md, not a backlog item.
- *Capture-input token + CanvasCoord distinct type + cursor-
  after-draw policy unification + endItem slim variant +
  pushTransform-as-guard* — speculative without a real use
  case; deleted to keep the backlog honest.
