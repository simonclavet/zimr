# The profiler, v2: more useful, and one call away from any example (PLAN - UNDER REVIEW)

Status (Oct 12): S0 is done - `examples/profiler_flamegraph` runs on today's API (web, Windows build, smoke
PASS, lint clean). Decisions D1-D5 in section 9 are answered; the plan waits for Simon to confirm the whole
list and to say go. Nothing in `src/` has changed.

`profiler.md` is the v1 design (Tracy-inspired, in-process, worst-frame-first) and everything it scheduled
is built; its STATUS section is stale. This file is v2.

## 1. The ask

Simon, Oct 12: make the profiler more useful and easier to use in examples. Not a general debugging UI
imposed on every example - an example should be able to make the profiler and see it as a UI element with
little code, the way `zimrphysics_demo` does. Maybe it is already good enough. Show the flamegraph in the
simplest possible example, with sleeps, so the flamegraph is plainly visible.

## 2. What exists

**Collection, `src/profiler.zig`** (L0, no deps but `zm` and `build_options`):

    const zone = z.profiler.zone(@src());          defer zone.end();   // named after the enclosing fn
    const zone = z.profiler.zoneNamed(@src(), "x"); defer zone.end();
    zone.text("...") / zone.value(n) / zone.setColor(c)                 // per-call annotations
    z.profiler.frameMark()                                               // the engine calls it per frame
    freeze / unfreeze / isFrozen / armAutoFreeze / disarmAutoFreeze / autoFroze / reset
    worstFrame / frameAt / frameZones / srcOf / aggregate / frameSeriesFor / frameMeanMs / gpuMsMean

Static rings in BSS: 256 frames, 65 536 zone events shared across frames, 1 024 call sites. Compiled out
in `ship` (every entry point an empty inline). The clock is installed by `App.run` (`wgpu.nowMs`:
`performance.now()` on the web, `monotonicMilliseconds` natively) and probed for resolution.

**Engine zones**, `src/wgpu_app.zig`: `frameMark` at the top of `update`, then `frame` > `update` >
{`beginDrawing`, `endDrawing`} and `input.endFrame`. `zimrphysics`, `zimrphysics2d` and `robot` add phase
zones of their own.

**Views, `src/profiler_ui.zig`**: `panel(u)` = a header line (worst frame of the last 2 s, fps, timer
resolution, CPU/GPU means, an auto-freeze notice), `frameStrip` (one bar per frame, 60 fps budget line,
worst frame tinted), then tabs: `flamegraph(u, frame)` (an icicle of the worst frame, hover tooltip) and
`statsTable` (per call site over the window; a clicked row shows that site's per-frame histogram). The app
owns the window, the button and the freeze; the profiler takes no input of its own.

**Callers in examples:**

| example | what it does with the profiler |
|---|---|
| `zimrphysics_demo` | the reference integration: Profile button (freeze + pause the sim), Watch button (auto-freeze on a spike), a window with `panel`, four render zones. About 40 lines. |
| `zimrphysics2d_demo` | reads `aggregate` itself and prints the `p2d.*` phase means inline in its own panel |
| `cartpole_duel`, `mpc_cartpole`, `catch`, `three_leg`, `tracking`, `friction_slope` | `freeze()` around a planner or a 500 Hz control loop to MUTE recording (save `was_frozen`, restore after) |
| `geno_train`, `geno_ppo`, `getup_train`, `track_train` | `freeze()` once at init: recording muted for the app's whole life |

## 3. Is it already good enough? What the example measured

`examples/profiler_flamegraph` pretends to be a game frame: `simulate` (`broadphase`, `narrowphase`,
`solve`), `think` (`pathfind`), `cull`, and once a second `loadLevel` - each a function whose first line is
`z.profiler.zone(@src())` and whose body spins on the clock (the browser's main thread cannot block, so a
sleep is a spin). Two sliders set `solve` and the level load; a Freeze/Live button; then `panel(u)`.

**The collection API is good.** One line per function, named for free from `@src()`, frames marked by the
engine. Nothing to change there for ease of use.

**The view is usable as is**, and it costs an example: a `UiHost` and a font (most examples with any UI
already have both), a window, one call. About 25 lines with a freeze button; the physics demo's 40 include
pausing its simulation and the Watch toggle.

So for the simple case it IS nearly good enough. But building the example, capturing it, and probing
`profiler.zig` with a fake clock turned up the findings below, two of them real bugs.

## 4. Findings

**F1 - BUG: unfreezing records the whole frozen period as one frame.** While frozen, `markFrame` returns
before advancing `cur_t0`, so the first frame after `unfreeze` spans everything since the freeze. Probe
(fake clock, 30 frames of 16 ms, freeze, 300 frames, unfreeze): **the newest frame is 4 816 ms, it is the
worst frame of the window, and with auto-freeze armed the profiler RE-FREEZES on it at once.** That is the
physics demo's Watch mode: resume, and it snaps back to frozen on a bogus frame.

**F2 - BUG: a frame with more zones than the ring overwrites itself.** Probe: one `planner` zone holding
70 000 `robot.step` zones; the frame's first zone reads back as `robot.step`, depth 1. The outer zone's
`end()` also writes its end time into a slot that has since been reused. Nothing checks whether a frame's
zones are still in the ring - `frameZones`, `aggregate` and `worstFrame` read whatever is there.

**F3 - `freeze` does two jobs.** It is the user's "hold this snapshot", and six examples use it to MUTE
recording around heavy work (the comments measure why: 12 225 clock calls a frame, Node's heap exhausted
in the smoke runner, 5 602 host calls a frame in `three_leg`). Muting by freezing hides the heavy work
from the profiler entirely - the planner, the one thing worth seeing, never appears - and the two uses
have to negotiate through a saved `was_frozen`.

**F4 - the "worst frame" is chosen by wall time, idle included.** Frame duration is mark to mark: vsync
waits, a throttled tab, a debugger pause all count. Captured in the browser pane: a 1 020 ms stall became
"worst frame in last 2s: 1020.80 ms (1 fps)", and the frame strip, scaled to the worst bar, flattened
every other frame to nothing. A hitch hunt wants the frame with the most WORK (the engine's `frame` zone),
and the strip wants a scale that one outlier cannot destroy.

**F5 - flamegraph readability.** Seen in the capture: labels are not clipped (`pathfind` spills past its
bar, `narrowphase` is cut to `narro` by its neighbour); no durations on the bars, only on hover; rows and
text are fixed at 18 px / 12 px while the UI around them scales with `scaleToViewport`; narrow zones get
no label at all. Not seen but read: every zone is drawn, however narrow (a 60 000-zone frame is 120 000
draw commands); no zoom, no pan, no time ruler; no way to look at any frame but the worst.

**F6 - recorded, never shown.** `zone.text()`, `zone.value()`, `zone.setColor()` and `SourceLoc.color` are
stored per zone and no view reads them. Nothing calls them either (grep: 0 callers).

**F7 - statistics are inclusive only.** `frame` and `update` top the table on every run; the
what-to-optimise number is SELF time (a zone minus its children). `count` is per window, not per frame.

**F8 - the budget line is 60 fps, hard-coded.** Phones here run at 120 Hz.

**F9 - `profiler_ui` keeps its selection in a module variable** (`selected_src`), against house rule 8.

## 5. Every option, per question

### 5.1 How does an example show the profiler?

  a. **Today's.** The app owns a window, calls `panel`, and writes its own freeze button.
  b. **`profiler_ui.window(u, opts)`, a free function.** A complete window - title, Freeze/Live, Watch, the
     panel - with its state (open, selection, zoom) in module variables of `profiler_ui`.
  c. **A caller-owned view value.** `profiler: z.ProfilerView = .{}` in the app's State; `s.profiler.window(u)`
     draws it (when open), `s.profiler.button(u)` is a toggle for the app's own panel. Selection, zoom and
     the open flag live in the value.
  d. **A self-contained overlay** owning its own `UiHost`, for examples with no UI at all:
     `z.ProfilerOverlay.init(gpa, font)` / `.draw(f)` / `.deinit()`.
  e. **An engine overlay on a hotkey, for every app.** Rejected by the ask: imposed on all examples.
  f. **Opt-in `AppSpec` field** (`.profiler_overlay = true`): the runtime draws it with an engine-owned
     `UiHost`. Not imposed, but the engine then owns a UI context and a font, and two UI contexts compete for
     the same input every frame.

### 5.2 Heavy sections (F2, F3)

  a. Keep freeze-to-mute.
  b. `profiler.mute()` / `unmute()`, a nestable counter: no zones while muted, frames still marked.
  c. **A collapsed zone**: `zoneCollapsed(@src(), "planner")` records itself and suppresses everything under
     it while open, counting what it suppressed (shown in its tooltip). The planner's TIME stays visible; the
     60 000 steps inside it cost nothing.
  d. A global maximum depth.
  e. **A per-frame zone budget**: past N zones in one frame, stop recording (before reading the clock) and
     count the drops. A safety net, not a tool - it still pays for the first N.

### 5.3 Which frame the views show (F4)

  a. Worst by wall time (today).
  b. **Worst by work** - the engine `frame` zone's duration - as the default.
  c. **Click a bar in the strip to pin that frame**; a "worst" button returns to automatic.
  d. Pinning also freezes: a pinned frame on a live ring is overwritten within 2-4 s, so inspecting it
     without freezing ends mid-thought.

### 5.4 Flamegraph

Clip each label to its bar; "name 1.23 ms" when there is room; rows and text from the UI's font size; a
time ruler; wheel zoom around the cursor, drag to pan, click a zone to zoom to it, double-click to reset;
zones under a pixel merged per row into one grey sliver; a tooltip with name, file:line, inclusive and self
time, share of the frame, and the zone's text and value; the zone's colour when it set one.

### 5.5 Statistics

Self time and per-frame mean columns, sorted by self time; selecting a row highlights that call site's bars
in the flamegraph (the selection already exists, for the histogram).

### 5.6 Overflow and validity (F2)

A frame whose first zone has been overwritten (`zone_seq - zone_first > zone_cap`) reports itself expired:
`frameZones` yields nothing and the views say so. With 5.2e, a frame can never wrap the ring by itself.

### 5.7 Unfreeze (F1)

While frozen, `markFrame` keeps the in-progress frame's start current (and leaves the baseline alone), so
unfreezing starts a fresh frame instead of recording the freeze.

### 5.8 Later

Counters (`profiler.plot("bodies", n)` drawn as a sparkline), a Chrome-trace export, per-pass GPU zones, a
budget from the measured refresh rate (F8) - or simply 120/60 picked by the median frame.

## 6. Preferred choices, and why

- **5.1c, the caller-owned `ProfilerView`.** It is what zimr does everywhere else (the app owns its state;
  `UiHost`, `Font`), it fixes F9 rather than adding more module state, and two calls cover the whole
  integration. 5.1b is shorter by one field but grows module globals; 5.1d is worth having later for
  examples with no UI; 5.1f buys the last few lines at the price of a second UI context in the engine.
- **5.2c + 5.2e.** The collapsed zone replaces freeze-to-mute in all ten examples AND shows the planner's
  time, which is the point of a profiler; the budget makes F2 impossible whatever anyone writes.
- **5.3b + 5.3c + 5.3d.** Work is what a hitch hunt means; clicking a frame is the interaction every
  profiler has; and freezing on the click is the only way the picked frame survives being looked at.
- **5.4, 5.5, 5.6, 5.7 all**, in that order of value: F1 and F2 first because they are wrong answers, then
  readability, then interaction.
- **5.8 deferred.**

## 7. The API it adds up to (sketch, not final)

```zig
const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    profiler: z.ProfilerView = .{},
};

fn update(f: *z.Frame, s: *State) void {
    const u = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    if (u.window("controls", .{})) |w| {
        defer w.close();
        s.profiler.button(u); // "Profiler": opens and closes the window below
    }
    s.profiler.window(u); // the whole profiler: Freeze/Live, Watch, strip, flamegraph, statistics

    if (!z.profiler.isFrozen()) { // optional: hold the scene while its profile is being read
        step(s);
    }
}

fn plan(s: *State) void {
    const zone = z.profiler.zoneCollapsed(@src(), "planner"); // its time shows, its 60 000 steps cost nothing
    defer zone.end();
    ...
}
```

## 8. Stages

- **S0 - the simplest example. DONE.** `examples/profiler_flamegraph`, on today's API.
- **S1 - correctness.** F1 (unfreeze), F2 (validity + per-frame budget), worst-by-work and a strip scale
  that one outlier cannot flatten (F4). Each fix lands with a fake-clock test seen red first; the two probes
  of section 4 become those tests.
- **S2 - `ProfilerView`.** `window` and `button`; selection state moves into it (F9); the example and
  `zimrphysics_demo` move onto it.
- **S3 - flamegraph readability (F5, F6).** Clipped labels with durations, font-relative sizes, sub-pixel
  merging, a ruler, the full tooltip, zone colours.
- **S4 - interaction.** Pick a frame from the strip (and freeze), zoom and pan.
- **S5 - statistics (F7).** Self time, per-frame means, row highlights in the flamegraph.
- **S6 - collapsed zones.** `zoneCollapsed`; the ten freeze-to-mute examples move to it, and their
  planners show up in their profiles for the first time.
- **S7 - the design moves into code.** `profiler.zig`'s `//!` doc becomes the architecture; `profiler.md`
  and this file go to `archive/`. Later items (5.8) as asked.

## 9. Decisions

Asked one at a time; each records the choice and the reason once answered.

- **D1 - how an example shows the profiler** (5.1). **DECIDED Oct 12: c, a caller-owned `ProfilerView`**
  (`profiler: z.ProfilerView = .{}` in State; `s.profiler.window(u)`, `s.profiler.button(u)`). The app owns
  the view's state as it owns `UiHost` and `Font`, and `profiler_ui`'s module variable goes away with it.
  The overlay (5.1d) stays a possible later addition for examples with no UI.
- **D2 - heavy sections** (5.2). **DECIDED Oct 12: c + e.** `zoneCollapsed(@src(), name)` records itself
  and skips (and counts) everything under it while open, so a planner's time shows and its inner zones cost
  nothing; a per-frame zone budget stops recording before the clock read and counts the drops, so F2 cannot
  happen. The ten freeze-to-mute examples move to collapsed zones, and `freeze` means only "hold this
  snapshot".
- **D3 - which frame the views show** (5.3). **DECIDED Oct 12: b + c + d.** By default the frame with the
  most work (the engine's `frame` zone), not the longest mark-to-mark. Clicking a strip bar pins that frame
  and freezes; a "Worst" button returns to automatic. Strip bars get a hover tooltip, and the strip's scale
  is capped so one outlier cannot flatten it.
- **D4 - flamegraph scope** (5.4). **DECIDED Oct 12: all of it, in two stages.** S3 readability (clipped
  labels with durations, font-relative sizes, sub-pixel merging, a ruler, the full tooltip, zone colours),
  then S4 interaction (wheel zoom at the cursor, drag to pan, click a zone to zoom to it, double-click to
  reset). Each stage is looked at before the next starts.
- **D5 - order.** **DECIDED Oct 12: correctness first, on its own.** S1 lands alone, each fix with a
  fake-clock test seen red first, then S2, S3, S4, S5, S6, S7 in that order.

## 10. Journal

**Oct 12.** Studied `profiler.zig`, `profiler_ui.zig`, the engine's zones and every example that touches
the profiler. Built `examples/profiler_flamegraph` (registered in `build.zig`'s `wgpu_apps` and the
gallery manifest; editor configs regenerated, additions only). Web release build, Windows release build,
`lint-check` and `smoke-test -Dfocus=profiler_flamegraph` all green (smoke: init 4 178 calls, ~268 a
frame). Captured the canvas in the browser pane: the flamegraph shows `frame > update > simulate / think /
cull / loadLevel / drawPanel` and their children as designed, and the same capture showed F4. Two probes
against the real `profiler.zig` with a fake clock (a scratch test, not in the tree) confirmed F1 and F2.
Simon answered D1-D5, each the recommended option; recorded in section 9. Waiting on his confirmation of
the full list and a go before S1.
