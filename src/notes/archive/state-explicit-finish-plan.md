# state-explicit refactor — finish plan

*Written turn 23.  Forward-looking plan to take the codebase
from 65 production `globalX()` reaches across 44 fns down to
zero outside named JS-bridge thunks.  Replaces the "Phases ahead"
section of `state-explicit-completion-plan.md`.  Sister docs:*

- `state-explicit-plan.md` — original architecture vision
  (Runtime, Frame, the discipline).  Authoritative for *what
  the end state looks like*.  This plan is *how we get there*.
- `state-explicit-completion-plan.md` — accumulated workflow,
  lessons learned across turns 1-21.  Authoritative for *the
  per-fn workflow and pitfalls*.

---

## Why we are doing this — extreme explicitness

**The single goal: every zimr function declares, in its
signature, exactly which pieces of state it reads and which it
writes.**  No exceptions.  No hidden globals.  No "framework
just knows".

The function-level explicit-state work is fixed regardless of
where each substate lives.  What follows from this single goal
is two structural rules about substate storage:

### Rule 1 — Runtime stays small and disciplined

State lives in `Runtime` (and is reachable via `Frame`) when:

  - The JS bridge needs it at a known address (`input`, `time`,
    `window`, `audio_device`).  These are non-negotiable.
  - **OR** virtually every zimr app uses it (`gl`, default
    fonts, `shapes_texture`).  These earn their Runtime spot
    by amortising the cost across all users.

This is a pragmatic call, not a strict criterion.  When in
doubt, default to Runtime.  Push to user `State` only when
both are true: the substate is genuinely opt-in (many apps
won't use it) AND the framework's storage cost is meaningful
(e.g., several MB of audio buffer tables).

### Rule 2 — Feature-specific resource pools live in user State

When a feature is **opt-in** — most zimr apps don't use it —
its resource pools live in user `State`, not `Runtime`.  zimr
provides the type and the init/deinit fns; the user decides
whether to include the field.

The clearest case is **audio**.  An app that wants to play
music and sounds adds:

```zig
const State = struct {
    audio: z.audio.State,   // bundles MusicTable + SoundTable + StreamTable + WaveAllocTable
    bgm: z.audio.Music,
    // ...
};
```

The framework provides `z.audio.State` (a struct bundling the
four tables) and operations that take `*z.audio.State` as a
parameter.  Apps that don't play audio get zero overhead — no
tables allocated, no dispatch hooks for audio events touching
unused state.

### Rule 3 — Frame doesn't grow with feature-specific state

`Frame`'s shape is a contract: it carries the universal
substates and the per-tick channels.  When zimr adds a new
feature, it generally does **not** get a new Frame field.
Either the feature is universal (rare; goes in Runtime, gets
a Frame ref) or it's opt-in (goes in user State, no Frame
field).

The current Frame shape (post-Phase-B.2) is:

```zig
pub const Frame = struct {
    gpa: Allocator,
    scratch: Allocator,
    loader: Loader,             // vtable
    clock: Clock,               // vtable
    rng: Rng,                   // vtable
    log: Logger,                // vtable

    input: *const InputState,
    window: *const WindowState,
    gl: *GlState,
    shapes_texture: *const ShapesTextureState,
    skybox_cache: *SkyboxCache,
    ui: Ui,
};
```

Twelve fields.  We may revisit later — `skybox_cache` is the
borderline case (only skybox apps use it).  But the principle
holds: new feature ≠ new Frame field.

---

## Non-goal: ergonomics

**Verbose call sites are acceptable.**  Once every fn takes
its substates as explicit parameters, calls look like:

```zig
z.shapes.drawRectangle(f.gl, f.shapes_texture, x, y, w, h, color);
z.text.drawEx(f.gl, f.fonts, line_spacing, font, "hi", pos, sz, sp, col);
z.audio.music.play(&state.audio, my_music_handle);
```

Yes, that's wordier than `z.drawRectangle(x, y, w, h, color)`.
**That is fine.**  Explicitness wins over conciseness in this
phase.  Users can wrap whatever bundle they prefer in their
own helper fn — but the underlying zimr API stays explicit.

When the explicit-state migration is complete and the codebase
is stable in that shape, **we may revisit ergonomics** by
introducing convenience methods on user State or on Frame.
Convenience layers are easy to add on top of an explicit
foundation, hard to subtract from a convenient-but-implicit
one.

---

## Non-goal: hot reload

Hot reload was at one point a primary motivator (see
`hotreload-design.md`, written turn 26).  As of turn 28, it is
**no longer a driving concern**.  The design memo is preserved
because the explicit-state work happens to make hot reload
easy later, but we are not designing the API around it.  If
hot reload arrives, it falls out cleanly.  If it doesn't,
that's fine.

---

## Side benefits (not goals, but real)

The explicitness goal happens to deliver these too:

  - **Mockability**: a test driving any fn constructs its
    substates as stack-locals — no `Runtime` fixture, no
    anchor plumbing.  Already worked for fns that have been
    migrated.
  - **Multiple backends**: a software renderer would be a
    second `*GlState` instance the user threads to a different
    set of fns.  Hot-swappable per-region.
  - **Reasoning about thread safety** (if/when wasm threads
    arrive): every fn declares its mutation surface, so a
    "this fn is read-only on Runtime" claim is compiler-
    checked.
  - **Hot reload** (per above) — falls out for free if we
    want it later.

These are nice but they are *not the reason* we're doing this
work.  The reason is **explicitness**, full stop.

---

## Design principles — two questions to ask of every substate

### Question 1 — per-call parameter or shared system state?

Decided turn 25 after the line_spacing migration churn made it
visible.  Before migrating any "global setting" mechanically,
ask:

> **Is this state genuinely shared across many call sites that
> expect to read the same value, or is it a parameter that each
> call site could express directly?**

If shared system state, treat it as a substate (introduce a
type, thread it explicitly).  If a per-call parameter
masquerading as a setting, **delete the setter** and make it a
parameter on the fns that need it.  Users who want a
project-wide value lift it into their `State`.

Worked applications:

- **`setLineSpacing` / `setTextLineSpacing`** — per-call.
  Deleted in B.1.  Lives nowhere now — each text fn takes
  `i32 line_spacing` as a parameter; users wanting a project
  default put it in their `State` or pass a literal.
- **`setShapesTexture`** — shared.  Substate stays.  Migrates
  as `*ShapesTextureState` to user `State` (per Question 2
  below).
- **`setMasterVolume`** — shared.  Read by every audio playback
  during dispatch.  Substate stays as `*AudioDeviceState`.  The
  device is JS-bridge-anchored (per Question 2), so it stays
  in `Runtime`.
- **Default font cache** — *resource*, not setting.  Substate
  stays as `*FontCache`, moves to user `State`.

### Question 2 — Runtime or user State?

Decided turn 28; refined turn 29 toward pragmatism.  For every
shared substate (the ones that survived Question 1), ask:

> **Do we expect virtually every zimr app to use this, or is
> it a feature that many apps won't need?**

If universal (every drawing app uses `gl`; every text-using
app uses the default font; every shape draw uses
`shapes_texture`), the substate stays in `Runtime` and Frame
gets a ref.  This earns the framework's storage cost via
near-universal usage.

If opt-in (audio, perhaps gestures or skybox in future
applications of the lens), the substate moves to user `State`.
zimr provides the type + init/deinit; the user reserves a
field.  Cost of the feature becomes visible in the user's
struct definition.

**JS-bridge requirement still trumps everything.**  If JS
event handlers or audio-decode callbacks must find the
substate at a known address, it stays in Runtime regardless
of how many apps use the feature (`audio_device` is the clear
example — only audio apps "use" it, but it MUST live in
Runtime because JS reaches for it).

**When in doubt, default to Runtime.**  Push to user State
only when the feature is *clearly* opt-in.  Premature
relocation to user State creates verbose example State
definitions for no clear benefit.

Worked applications (turn 29 final categorisation):

| Substate | Decision | Rationale |
|---|---|---|
| `input` | Runtime | JS-bridge + universal |
| `time` | Runtime | JS-bridge + universal |
| `window` | Runtime | JS-bridge + universal |
| `audio_device` | Runtime | JS-bridge (despite being audio-only) |
| `gl` | Runtime | universal (every drawing app uses) |
| `drawing.shapes_texture` | Runtime | universal (every shape draw) |
| `drawing.default_font` (rename: `FontCache`) | Runtime | most apps draw text |
| `audio.{music,sounds,streams,waves}` | **user State** | opt-in: audio is a feature, not a baseline |
| `drawing.skybox_cache` | Runtime (for now) | small cost; revisit if skybox grows |
| `gestures` | Runtime (for now) | small cost; revisit if more gesture features arrive |
| `fps` | Runtime | small derived state, used by drawFPS |
| `tracelog` | Runtime | log-emission filter, used by every log path |
| `ui_context` | Runtime (for now) | UI is widely useful; revisit later |

The "for now" tag flags candidates we may revisit when their
storage cost becomes meaningful or when a clear opt-in/opt-out
boundary emerges.  Today's pragmatic call: only audio moves to
user State.  Everything else earns its Runtime spot.

The lens removes work from the queue (the line_spacing case), it
doesn't add complexity to the migrations that remain.

---

## Where we stand (turn 26 baseline — refresh per turn)

Audit run by `scripts/count_globals.py`:

```
File            Prod  Tests  Fixtures
drawing.zig        7      0       0
rlgl.zig           0      0       0
sound.zig         21    103      46
runtime.zig       24      0       5
ui.zig             5      0       0
zimr.zig           0      0       0
              ─────  ─────  ──────
TOTAL             57    103      51
```

Build state: **green** — 874/874 native + 90/90 wasm.
Phase B.1 landed turn 26 — `setLineSpacing` family, the
`globalLineSpacing` accessor, `Runtime.drawing.line_spacing`,
`Frame.line_spacing`, `UiContext.line_spacing` and the dispatch
stamping all gone.  `Style.line_spacing` lives in the UI's
style; `DrawCmd.text` carries per-cmd line_spacing for the
deferred replay path.  Examples sweep: `f.line_spacing` → literal
`2` (134 sites).

Hot-reload design memo saved to `src/notes/hotreload-design.md`
locking three constraints (no pointers in State, user-provided
ser/de, best-effort fallback to cold start).  No code change
this turn from that memo — design recorded for Phase F.

JS-bridge anchor: still named `anchor`, no underscore prefix.

Of the 57 production reaches (down from 65 at turn 23, 59 at
turn 25):

  - **43 are real migration work** in 26 fns (text default-font
    cluster ×7, sound.zig × 21, camera × 10, ui-eager-mode × 5).
  - **14 are JS-bridge thunks** in 2 namespaces (input × 10,
    effects vtable × 4) — these *should* keep an anchor read,
    but consolidated to one helper per family in Phase E.

103 test-body reaches and 51 anchor fixtures retire as a side
effect of the corresponding prod migration — every prod fn we
migrate, its tests stop needing the fixture and the test bodies
construct stack-local substates.

---

## The eight phases — with concrete payload

Each phase is one focused turn.  Quality over speed: the goal is
clean, commented, readable code where every fn's signature
visibly answers "what does this read?  what does this write?"
A turn that delivers 1 fn beautifully migrated is better than a
turn that delivers 5 with sloppy comments.

| Phase  | What                                                          | Prod Δ | Fix Δ | Substate destination | Notes |
|--------|---------------------------------------------------------------|-------:|------:|---|---|
| **B.1**| drawing.zig — line_spacing **deletion**                       |  −2    | 0     | (deleted entirely) | ✅ DONE turn 26.  Per-call lens. |
| **B.2**| init-Frame symmetry                                            | 0      | 0     | n/a | ✅ DONE turn 27.  `initState(f: *Frame)`. |
| **B.3**| drawing.zig — default_font cluster + scarlet                  |  −7    | 0     | Runtime/Frame | `FontCache` (renamed from `FontDefaults`) stays in Runtime; Frame gets `*FontCache` ref.  Universal usage. |
| **C1** | sound.zig — `music.loadFromMemory`                            | −7     | −11   | **user `State`** | `MusicTable` moves to user `State` (audio is opt-in). |
| **C2** | sound.zig — `sounds.loadFromMemory/loadFromWave`              | −8     | −8    | **user `State`** | `SoundTable` moves to user `State`. |
| **C3** | sound.zig — `streams.load` + composer                         | −5     | −17   | **user `State`** | `StreamTable` moves to user `State`. |
| **C4** | sound.zig — `waves.run` + audio_device residual               | −1     | −10   | mixed | `WaveAllocTable` → user; `AudioDeviceState` stays Runtime (JS-bridge). |
| **C5** | runtime.zig — camera projection helpers                       | −10    | −3    | Runtime/Frame | `GlState` is universal — stays in Runtime; cameras take explicit `*const GlState` from `f.gl`. |
| **D**  | ui.zig eager-mode + DrawList replay                           | −5     | 0     | Runtime/Frame | `UiContext` stays in Runtime/Frame for now.  Eager-mode reaches retired. |
| **E**  | Anchor minimization + JS-bridge cleanup                       | −14    | 0     | (Runtime — JS-bridge) | 14 thunks → ~5 anchor reads, all named.  Anchor renamed to `_js_bridge_anchor`. |
|        | **Total to explicit-state endpoint**                          | **−57**| **−49**| | Runtime keeps universal substates; only audio tables move out. |

After E: Runtime contains ~12 substates today minus the four
audio tables.  The audit metric is at zero; every fn signature
documents its substate access; users opt in to audio by
reserving a `z.audio.State` field.  This is **the goal**.

Phases F+G from turn 28's plan (relocate
`shapes_texture`/`skybox_cache` and eliminate
`fps`/`tracelog`/`gestures`) are **deferred indefinitely** —
the pragmatic position is "if the substate isn't clearly
opt-in, leave it in Runtime."  We may revisit if a substate's
cost becomes meaningful or if its opt-in nature becomes clear.

---

## Per-turn workflow — the detailed loop

### Pre-flight checklist (every turn)

1. **Run `python3 scripts/count_globals.py`** — refresh the
   metrics block in this doc with the current numbers.  If the
   numbers don't match yesterday's expectation, stop and audit.
2. **Read style guide** if 3+ turns since last read.  Track at
   the top of `## Style guide read log` below.  Rules 1-7 fade
   from memory between checks.
3. **Re-read this section's "Why we are doing this"** if 5+
   turns since last read.  The why drives quality decisions.
4. **Pick the next fn(s)** per the active phase's ordering.
   Verify they're leaf-eligible: every `globalX()` call in
   the body forwards into either an already-state-taking fn
   or an internal helper that will be cascaded this turn.

### The per-fn workflow (verbatim from completion plan, with
quality additions)

For every fn migrated:

1. **Pick.** Choose a leaf-eligible fn.  If a candidate's body
   reaches into another unmigrated fn, either cascade the chain
   in this turn (when it's ≤3 fns) or pick a different leaf.

2. **Read the body end to end.** Understand what it does
   *before* threading state.  This is the user's directive.
   The substate decisions emerge from the read, not from the
   call-graph alone.

3. **Map callers.**
   `grep -rnE '\bfn_name\(' src/ examples/`.  Note every site,
   how each currently has access to substates (or doesn't yet),
   and which idiom each will use post-migration:
     - `&app.runtime.X` when `*App` is in scope
     - `f.X` when `*Frame` is in scope
     - cascade the caller fn (it migrates this turn too)
     - documented scarlet letter (rare; only when cascading
       would balloon the turn)

4. **Map tests.** `grep -nB1 'fn_name(' src/<file>.zig` near
   `test "..."` markers.  For each test using an anchor fixture:
     - identify which substates need stack-local equivalents,
     - check `defer` chains for transitive global reaches
       (Lesson #13: deinit/unload paths are easy to miss).

5. **Determine substates.** What does the body read?  What
   does it mutate?  Each gets its own parameter.  Discipline:
   *no fn takes the whole `Frame`*.  A fn needing `gl + window`
   takes `gl: *GlState, window: *const WindowState`, not
   `f: *Frame`.

6. **Migrate the signature.** Substate params come **first**,
   then user-meaningful args.  Apply Rule 1: arg-per-line for
   any multi-arg fn.  Closing `)` on its own line at the `pub
   fn` indent.  Const-correctness: `*const X` for reads, `*X`
   for mutates.

7. **Migrate the body.** Replace `globalX()` calls with the
   new local parameter.  If the body calls another fn that
   needed `*GlState`, forward the local param.

8. **Migrate the doc comment.**  This is new and important:
   - State explicitly what's read and what's written.
   - State allocator ownership if the fn takes `gpa`.
   - State error conditions.
   - Drop any reference to retired globals.

   Example (good):
   ```
   /// Loads a Music handle from in-memory bytes.
   ///
   /// Reads: `*const AudioDeviceState` for device sample rate +
   /// context id (audio cannot upload without a live device).
   /// Reads: `*waves.AllocTable` for the WAV decode path's
   /// transient Wave (released before return).
   /// Mutates: `*MusicTable` (allocates a slot).
   /// Allocator: `gpa` is used for transient decode buffers
   /// only — the Music handle owns no Zig-side memory; cleanup
   /// is via `unload(state, music)`.
   pub fn loadFromMemory(...) !Music
   ```

9. **Migrate the callers.**  Per the idioms in step 3.  Apply
   Rule 6 if any call site has bare numeric/boolean literals
   with non-self-evident meaning.

10. **Migrate the tests.**  Tests of the migrated fn drop the
    4-line anchor fixture preamble.  Replace with stack-local
    constructs:
    ```zig
    var dev: audio_device.AudioDeviceState = .{};
    audio_device.init(&dev);
    defer audio_device.close(&dev);
    var ws: waves.AllocTable = .{};
    var mt: MusicTable = .{};
    ```
    Each fixture retired is logged in the per-turn metrics
    block.

11. **Apply the styleguide to the WHOLE touched fn(s).**  Not
    just the lines you changed.  Per styleguide §"Enforcement":
    "the moment you edit a function, bring the whole function
    up to spec."  Run through Rules 1-7 mentally for every fn
    that appears in the diff.  Pay special attention:
    - Rule 1: every multi-arg fn declaration arg-per-line.
    - Rule 2: explicit local types (skip when type already on
      the line — allocs, casts).
    - Rule 3: braces on every `if`/`else`/`while`/`for` body.
    - Rule 4: comments casual, undecorated, unnumbered.
    - Rule 5: `@splat(value)` over `[_]T{value} ** N`.
    - Rule 6: lift bare literals at call sites.
    - Rule 7: trivial boolean conditions, lift work into named
      bools.

12. **Build verify.**
    - `zig build test --summary all` — must show 874/874 (or
      higher if tests added — never lower).
    - `zig build smoke-test --summary all` — must show 90/90.

13. **Quality re-read.**  Open the migrated fn.  Read the new
    signature aloud (mentally):
    - "Does the fn name + params + return type tell me what
      the fn does?"
    - "Does the doc comment tell me what's read and what's
      written?"
    - "Could a colleague mock this fn by passing stub state?"
    If any answer is no, edit until yes.

### End-of-turn checklist (every turn)

1. Refresh metrics block in **this doc** (`Where we stand`).
2. Append to `CHANGELOG.md` under `## [Unreleased]` —
   concise prose: what migrated, what payoff (which of the
   four user-visible ones), what built, what's next.
3. **Every 3 turns**: update `CHEATSHEET.md` if any public
   API surface changed, and update `PLAN.md`'s status snapshot.
4. `/home/claude/save-zimr.sh` — saves `/mnt/user-data/outputs/zimr.zip`.
   Unconditional, even on planning-only turns.
5. `present_files` the zip.

### Style guide read log

Re-read `style-guide.md` rules 1-7 at:

  - Turn 22 (initial)
  - Turn 23 (after archive cleanup, plan revision)
  - Turn 25 (after design-direction change — line_spacing as
    per-call parameter, init-Frame symmetry)
  - **Next due: turn 28**

---

## Phase B.1 — drawing.zig: line_spacing **deletion**

**Subsystem**: `drawing.text` namespace.  Per-call lens applied
(see §"Design principle"): `line_spacing` was never genuinely
shared system state — it's just an integer that text-drawing fns
need when handling `\n`.  This phase **deletes** the
shared-state framing introduced in earlier turns.

### Status entering this phase

Turn 24 left mid-state: text fns now take `line_spacing: i32`
as a parameter (correct), but the surrounding scaffolding is
all still in place (incorrect).  The scaffolding to **delete**:

1. `text.setLineSpacing` — public setter (Runtime field setter)
2. `text.setTextLineSpacing` — raylib-flavoured c_int alias
3. `text.globalLineSpacing()` — anchor-reaching accessor
4. `Runtime.drawing.line_spacing: i32` field (in `runtime_anchor.zig`)
5. `Frame.line_spacing: i32` field (in `zimr.zig`)
6. Frame.line_spacing dispatch stamping (in `dispatchUpdate`)
7. `Frame.subFrame` line_spacing inheritance line
8. `UiContext.line_spacing: i32` field
9. `UiContext.beginFrame`'s `line_spacing` parameter
10. `DrawList.render`'s `line_spacing` parameter

The scaffolding to **keep**:

- Every text fn still takes `line_spacing: i32` as its first
  parameter — that's the per-call-parameter design we're
  committing to.
- Helper fns in examples (`drawWorld`, `drawLandmark`,
  `drawRainbowHeading`, `drawWrappedTtf`) that took
  `line_spacing: i32` — keep the parameter; the caller now
  passes a literal.

### Where line_spacing lives at the *user-side* of the API

The UI's `Style` struct gains a `line_spacing: i32 = 2` field
(sits next to the existing `font_size` and `font_spacing`).
That gives `measureTextS` / `drawTextAtS` / the `.text` cmd
replay path a sensible source of value: `ctx.style.line_spacing`.

For example code that draws text directly: pass a literal
(e.g. `2`) at the call site, **or** lift to `State.line_spacing`
if the example wants a knob.  Most existing examples use
single-line strings where the value never affects layout — the
literal is fine.

For widget-emitted text in the UI's deferred path (`addText`
records a cmd; `render` replays): the cmd struct gains a
`line_spacing: i32` field stamped from `ctx.style.line_spacing`
at record time.  Replay reads from the cmd, not from a
parameter — `DrawList.render`'s signature reverts to `(self,
gl, window)`.

### Migration sequence (one turn)

1. Drop `Runtime.drawing.line_spacing` field.
2. Drop `Frame.line_spacing` + dispatch stamping + subFrame line.
3. Add `Style.line_spacing: i32 = 2`.
4. Drop `UiContext.line_spacing` + `beginFrame` parameter.
5. Update `measureTextS` / `drawTextAtS` to read
   `ctx.style.line_spacing`.
6. Add `line_spacing: i32` field to the UI's text command
   record (whatever struct backs `.text` cmds in DrawList).
7. Update `addText` to take `line_spacing` and store it.
8. Update `DrawList.render`'s `.text` arm to read from the cmd.
9. Drop `DrawList.render`'s `line_spacing` parameter.
10. Sweep examples: `f.line_spacing` → `2` (literal).
    `drawWorld`/`drawLandmark`/`drawRainbowHeading`/
    `drawWrappedTtf` keep their `line_spacing: i32` parameter;
    callers pass `2`.
11. Delete `text.setLineSpacing` and `text.setTextLineSpacing`
    fns from drawing.zig.
12. Delete `text.globalLineSpacing()` accessor.
13. Run audit script — drawing.zig drops to 14 prod reaches
    (15 → 14, the `globalLineSpacing` one retired).
14. Build verify: 874/874 + 90/90.

### Worked example — what changes for the user

**Before (turn-24 state, broken):**

```zig
fn update(_: *App, f: *Frame, state: *State) void {
    z.text.setLineSpacing(f.line_spacing, 2);              // field + setter
    z.text.drawEx(f.line_spacing, font, "hi\nbye", ...);   // read via Frame
}
```

**After Phase B.1:**

```zig
const State = struct {
    line_spacing: i32 = 2,   // user owns the storage
};

fn update(_: *App, f: *Frame, state: *State) void {
    z.text.drawEx(state.line_spacing, font, "hi\nbye", ...);
}
```

For users who don't want a knob, just pass the literal:

```zig
z.text.drawEx(2, font, "hi", pos, 16, 1, color);
```

### Phase B.1 exit criteria

- `globalLineSpacing()` removed; `setLineSpacing` /
  `setTextLineSpacing` removed.
- `Runtime.drawing.line_spacing` and `Frame.line_spacing` removed.
- `python3 scripts/count_globals.py` shows `drawing.zig: 14`
  (or fewer) — one prod reach retired.
- 874/874 + 90/90 green.
- CHEATSHEET.md updated: text-fn signatures + new "no
  setLineSpacing — pass an i32 to each text call" note.

### Snapshot label

`state-explicit-finish-1-line_spacing-deletion`

---

## Phase B.2 — init-Frame symmetry

**Subsystem**: `zimr.zig` (App.create dispatch + Frame
construction) + every example's `initState` + `update`
signature.

### Why this phase exists

Today the user-facing entry-point shape is asymmetric:

```zig
fn initState(app: *z.App) !State { /* uses app.gpa, app.runtime.X */ }
fn update(_: *App, f: *Frame, state: *State) void { /* uses f.X */ }
```

The asymmetry forces users to know two access patterns
(`app.runtime.drawing.X` at init, `f.X` in update) and propagated
ugliness into examples like `image_text.zig` during the line_spacing
work.  Phase B.1 above handles line_spacing; Phase B.2 fixes the
underlying asymmetry so subsequent phases (C1+) don't re-create
it for audio.

### The "first frame" model

> Init is the first frame.  By the time `update` runs, time has
> advanced and inputs have happened.  But the substates available
> to your code are the same in both places.

Per-tick fields default to honest zeros at init:

| Frame field | Init-time value | Notes |
|---|---|---|
| `gpa` (newly added) | App's gpa | long-lived allocator |
| `scratch` | fresh arena | reset between init and first update |
| `gl` | live GlState | already initialized |
| `window` | live WindowState | canvas dims known |
| `audio_device` etc | live AudioDeviceState | once Phase C lands these |
| `drawing` | live DrawingState | shapes_texture, default_font, skybox_cache |
| `loader`, `clock`, `rng`, `log` | configured vtables | usable |
| `input` | empty `InputState{}` | true: no events have fired |
| `time` | t=0, dt=0 | true: nothing has elapsed |
| `frame_index` | 0 | first frame |
| `ui` | inactive Ui handle | widgets not callable at init |

### New user-facing shape

```zig
fn initState(f: *z.Frame) !State {
    const tex = try z.loadTextureFromMemory(f.gpa, png_bytes);
    const sound = try z.sounds.loadFromMemory(f.sounds, f.audio_device, f.waves, f.gpa, ".wav", bytes);
    return .{ .tex = tex.id, .sound = sound };
}

fn update(f: *z.Frame, state: *State) void {
    f.clear(z.colors.black);
    z.shapes.drawRect(f.gl, f.shapes_texture, ...);
}
```

Both fns take `f: *z.Frame`.  `update` loses its unused
`_: *App` parameter (full symmetry).  No more
`app.runtime.X` reach pattern in user code.

### Implementation steps (one turn)

1. **Add `gpa: Allocator` to Frame** (in `zimr.zig`) —
   sourced from `app.gpa`; populated in dispatchUpdate AND
   the new init-Frame builder.
2. **Build a `firstFrame` helper** in `zimr.zig` that
   constructs a Frame with per-tick fields zeroed/empty.
   Used once at App.create after Runtime is fully alive.
3. **Decide UI-at-init**: pre-decision — `f.ui` is a Ui
   handle whose `beginFrame` has not been called.  Calling
   widgets at init is undefined; document with an assert in
   debug mode that fires if `ctx.frame_count == 0` AND a
   widget submission fn is called.  Most users won't trigger
   this.
4. **Change z.run signature** to dispatch `initState` with
   the firstFrame.  Existing `init_fn: fn (*App) !State`
   becomes `init_fn: fn (*Frame) !State`.
5. **Sweep all 24 examples**:
   - `fn initState(app: *z.App) !State` → `fn initState(f: *z.Frame) !State`
   - `app.gpa` → `f.gpa`
   - `app.runtime.X` → `f.X` (the X already exists on Frame)
   - `app.canvas_w` / `app.canvas_h` → `f.window.canvas_w` / `f.window.canvas_h`
   - Any other `app.X` access → check if Frame exposes; add field if not
6. **Drop `app: *App` from `update`'s signature** in z.run
   too.  Sweep: `fn update(_: *App, f: *Frame, state: *State)`
   → `fn update(f: *Frame, state: *State)`.

### Caller impact

24 example files touched.  Most edits are mechanical:
parameter rename + access-pattern sweep.  Build verify after
each batch — host and wasm.

### Phase B.2 exit criteria

- All 24 examples build wasm + host green.
- `app.runtime` reach not present in any example.
- `app.gpa` reach not present in any example.
- New API documented in CHEATSHEET.md and getting-started.md.

### Snapshot label

`state-explicit-finish-2-init-frame-symmetry`

---

## Phase B.3 — drawing.zig: default_font cluster + scarlet

**Subsystem**: `drawing.text` namespace.  7 prod reaches
remaining after B.1.  Three blockers plus the scarlet:

  - `globalDefaultFont()` — 3 reaches (`getFontDefault`,
    `loadFontDefault`, `unloadFontDefault`)
  - `loadFontDefaultImpl` body — 2 reaches into
    `core.globalTracelog()`
  - `getFPS` internal helper — 1 reach into `core.globalFps()`
  - `drawTexturePro` text-namespace shim — 1 reach into
    `rl_text.globalState()` (scarlet)

### Substate destination — **stays in Runtime/Frame**

Default-font cache is universal: most zimr apps draw text.
The substate stays in `Runtime.drawing.default_font` (renamed
to `font_cache` to reflect role) and Frame gets a ref:

```zig
// runtime_anchor.zig:
pub const Drawing = struct {
    shapes_texture: ShapesTextureState = .{},
    font_cache: FontCache = .{},      // renamed from default_font
    skybox_cache: SkyboxCache = .{},
};

// zimr.zig — Frame gets a new field:
pub const Frame = struct {
    // ... existing fields ...
    font_cache: *FontCache,    // mutable: load/unload mutate
};
```

Stamped each frame in `dispatchUpdate` from
`&app.runtime.drawing.font_cache`.  Same pattern as
`shapes_texture`.

`tracelog` and `fps` substates also stay in Runtime;
internal helpers (`loadFontDefaultImpl`, `getFPS`) take their
substate by parameter from the call site.

### Type rename: `FontDefaults` → `FontCache`

The struct's role is "loaded font resources" not "default font
settings".  Rename for clarity.  `FontDefaults` references
sweep across drawing.zig and runtime_anchor.zig.

### Migration order within Phase B.3

1. **Rename** `FontDefaults` → `FontCache`.  All references
   updated.
2. `getFontDefault(state: *const FontCache) Font` — leaf
   reader.
3. `loadFontDefault(state: *FontCache, gpa, gl, tracelog) !void`
   — needs `*GlState` + `*const TraceLogState` for atlas
   upload + log line.
4. `unloadFontDefault(state: *FontCache, gl: *GlState) void`.
5. `loadFontDefaultImpl(state, gl, tracelog)` — internal
   helper; both tracelog reaches resolve here.
6. **Scarlet retirement**: `drawTexturePro` text-shim takes
   `gl: *GlState` first arg; `drawCodepoint` (its single
   caller in drawEx/drawCodepoints/drawTextCodepoints chain)
   gets `gl` threaded.  Cascade:
     - `drawCodepoint(gl, font, cp, pos, font_size, tint)`
     - `drawEx(gl, line_spacing, font, ...)` — gets gl prepended
     - `drawCodepoints(gl, line_spacing, ...)`
     - `drawTextCodepoints(gl, line_spacing, ...)`
     - `draw(gl, line_spacing, ...)`, `drawPro(gl, line_spacing, ...)`
7. `getFPS()` internal helper — takes `*const FpsState` from
   call site.  `drawFPS` gets `fps: *const FpsState` prepended.
8. `imageTextEx` / `imageText` — CPU-only paths.  Already take
   `i32 line_spacing` from B.1; no gl threading needed.
9. Add `font_cache: *FontCache` to Frame; stamp it in
   dispatchUpdate + firstFrame.

### Caller impact

```zig
// Before B.3 (post-B.1):
z.text.draw(2, "hi", x, y, sz, c);

// After B.3 — text fns take *GlState (universal, in Frame),
// take font_cache when they need to read the default-font
// atlas (also in Frame), take line_spacing as before:
z.text.draw(f.gl, 2, "hi", x, y, sz, c);
```

(The font_cache comes into play for fns like `getFontDefault`,
not the typical draw path — `text.draw` uses the default font
internally, so it dereferences `f.font_cache` itself.)

### Caller impact for examples

Examples don't gain new State fields — Frame still carries
everything text-related.  Just sweep call sites to thread
`f.gl` into text fns.

### Phase B.3 exit criteria

- `python3 scripts/count_globals.py` shows `drawing.zig: 0`.
- 874/874 + 90/90 green.
- `Runtime.drawing.default_font` renamed to `font_cache`.
- `FontDefaults` type renamed to `FontCache`.

### Snapshot label

`state-explicit-finish-3-default-font-cluster`

---

## Phase C1 — sound.zig: `music.loadFromMemory`

**Subsystem**: `sound.music` namespace.  7 prod calls in 1 fn,
plus 11 test-body fixtures retiring.

**Substate destination**: `MusicTable` and `WaveAllocTable`
move to **user `State`** (bundled in `z.audio.State`).
`AudioDeviceState` stays in `Runtime` (JS-bridge).

### The cross-namespace pattern

`music.loadFromMemory` reads `audio_device.globalState()`
4× (sample rate, context id) and `waves.globalState()` 2×
(transient WAV decode), then mutates `state: *MusicTable`
(already a parameter).

### Substate decisions

```zig
pub fn loadFromMemory(
    state: *MusicTable,
    device: *const audio_device.AudioDeviceState,
    waves_state: *waves.AllocTable,
    gpa: std.mem.Allocator,
    file_type: []const u8,
    bytes: []const u8,
) !Music
```

Reads: `device` (sample rate, ctx id), `waves_state` (transient
Wave alloc).  Mutates: `state` (allocates a music slot).
Allocator: `gpa` for transient decode buffers; the returned
`Music` owns no Zig-side memory.

### Frame extension after Phase C1

```zig
pub const Frame = struct {
    // ... existing ...
    audio_device: *const audio_device.AudioDeviceState,
    music: *music.MusicTable,
    waves: *waves.AllocTable,
};
```

`audio_device` is `*const` because user code reads (sample
rate, ctx id, master volume) but doesn't mutate it from a
Frame — `setMasterVolume` etc. take `*AudioDeviceState`
directly when called from the App level.

### Test fixture retirement (11 fixtures in `music` namespace)

Pattern, per test:

```diff
 test "loadFromMemory: WAV path, ready immediately" {
-    const anchor_mod = @import("runtime_anchor.zig");
-    var rt: anchor_mod.Runtime = .{ .gpa = std.testing.allocator };
-    anchor_mod.anchor = &rt;
-    defer anchor_mod.anchor = null;
+    var dev: audio_device.AudioDeviceState = .{};
+    audio_device.init(&dev);
+    defer audio_device.close(&dev);
+    var ws: waves.AllocTable = .{};
     const ta = std.testing.allocator;
-    audio_device.init(audio_device.globalState());
-    defer audio_device.close(audio_device.globalState());
     var mt: MusicTable = .{};
-    const m = try loadFromMemory(&mt, ta, ".wav", codecs.audio.wav.test_sine_wav);
+    const m = try loadFromMemory(&mt, &dev, &ws, ta, ".wav", codecs.audio.wav.test_sine_wav);
     defer unload(&mt, m);
     ...
 }
```

Audit: `defer unload(&mt, m)` — does `unload` need state?  Read
its body before retiring fixtures; if it reaches `globalState`,
either cascade unload OR keep a partial fixture.

### Snapshot label

`state-explicit-finish-2-music-loadFromMemory`

---

## Phase C2 — sound.zig: `sounds.loadFromMemory` + `loadFromWave`

**Subsystem**: `sound.sounds` namespace.  8 prod calls in 2 fns,
8 test-body fixtures retire.

**Substate destination**: `SoundTable` moves to **user
`State`** (bundled in `z.audio.State`).  `AudioDeviceState` and
`WaveAllocTable` per C1.

### Migrations

```zig
pub fn loadFromMemory(
    state: *SoundTable,
    device: *const audio_device.AudioDeviceState,
    waves_state: *waves.AllocTable,
    gpa: std.mem.Allocator,
    file_type: []const u8,
    bytes: []const u8,
) !Sound

pub fn loadFromWave(
    state: *SoundTable,
    device: *const audio_device.AudioDeviceState,
    gpa: std.mem.Allocator,
    wave: Wave,
) !Sound
```

`loadFromWave` doesn't need `waves_state` — it consumes a
caller-owned `Wave`.  Verify by reading the body.

### Frame extension delta

```zig
sounds: *sounds.SoundTable,    // add this turn
```

### Snapshot label

`state-explicit-finish-3-sounds-cluster`

---

## Phase C3 — sound.zig: `streams.load` + composer

**Subsystem**: `sound.streams` (2 prod calls, 11 fixtures) +
`sound.composer` (3 prod calls, 6 fixtures).  Bundled — both
small.

**Substate destination**: `StreamTable` moves to **user
`State`** (bundled in `z.audio.State`).  Composer is stateless
in zimr; it forwards to streams.

### Migrations

```zig
pub fn streams.load(
    state: *StreamTable,
    device: *const audio_device.AudioDeviceState,
    sample_rate: c_uint,
    sample_size: c_uint,
    channels: c_uint,
) !AudioStream

pub fn composer.tone(
    seq: *Sequence,
    device: *const audio_device.AudioDeviceState,
    freq_hz: f32,
    duration_s: f32,
) !void

pub fn composer.silence(
    seq: *Sequence,
    device: *const audio_device.AudioDeviceState,
    duration_s: f32,
) !void

pub fn composer.finalize(
    seq: Sequence,
    device: *const audio_device.AudioDeviceState,
    waves_state: *waves.AllocTable,
) !Wave
```

`composer.Sequence` is a value-type buffer/cursor pair — it
isn't a Runtime substate.  Callers construct
`var seq: composer.Sequence = ...;` locally.  The cross-namespace
reads (device for sample rate, waves for finalize output) are
the only reaches that need plumbing.

### Frame extension delta

```zig
streams: *streams.StreamTable,    // add this turn
// composer: never on Frame (value type, locally owned)
```

### Snapshot label

`state-explicit-finish-4-streams-composer`

---

## Phase C4 — sound.zig: `waves.run` + audio_device residual

**Subsystem**: `sound.waves` (1 prod call, 10 fixtures) +
`sound.audio_device` (1 internal residual).

**Substate destination**: `WaveAllocTable` moves to **user
`State`** (bundled in `z.audio.State`).  `AudioDeviceState`
**stays in `Runtime`** — it holds the WebAudio context handle
which JS-side audio decode callbacks reach for; it crosses the
JS bridge.  This phase removes the *internal* residual reach
(an `audio_device` namespace fn calling `globalState()` on
itself); callers thread the substate explicitly.

### Migrations

```zig
pub fn waves.run(
    state: *AllocTable,
    device: *const audio_device.AudioDeviceState,
    seq: *composer.Sequence,
) !Wave
```

`audio_device`'s 1 internal residual: read the body, identify
which fn calls `globalState()` from inside `audio_device`
itself — likely a private helper.  Refactor to take
`*AudioDeviceState` as a parameter; update the internal caller.

### After Phase C4

`sound.zig`: 0 prod globalState calls, 0 anchor fixtures.  All
cross-namespace audio reads now go through explicit parameters.
**Mockability achieved**: any test or tool can drive any audio
fn with a stack-local device + table.

### Snapshot label

`state-explicit-finish-5-waves-audio-device`

---

## Phase C5 — runtime.zig: camera projection helpers

**Subsystem**: `runtime.camera` namespace.  10 prod calls in
4 fns, 3 fixtures retire.

**Substate destination**: `GlState` is universal — **stays in
Runtime/Frame**.  This phase just makes the camera helpers'
read-access explicit: each takes `*const GlState` from the
caller (typically `f.gl`) instead of reaching for
`rlgl_mod.globalState()`.  No relocation work.

### Migrations

All 4 camera helpers need `*const GlState` — they read
framebuffer dimensions and clip-plane distances from the GL
state for unprojection math.

```zig
pub fn getWorldToScreen(
    gl: *const rlgl.GlState,
    pos: Vector3,
    cam: Camera3D,
) Vector2

pub fn getWorldToScreenEx(
    gl: *const rlgl.GlState,
    pos: Vector3,
    cam: Camera3D,
    width: c_int,
    height: c_int,
) Vector2

pub fn getScreenToWorldRay(
    gl: *const rlgl.GlState,
    pos: Vector2,
    cam: Camera3D,
) Ray

pub fn getScreenToWorldRayEx(
    gl: *const rlgl.GlState,
    pos: Vector2,
    cam: Camera3D,
    width: c_int,
    height: c_int,
) Ray
```

`*const GlState` because none of these mutate GL state — they're
pure projection math reading framebuffer/clip-plane dims.  This
const-correctness is itself a payoff for goal #1.

### Caller impact

User code: examples that compute world↔screen typically have
`f.gl` already in scope (every Frame carries `gl: *GlState`).
Frame method shims forward to namespace fns — update both.

### Snapshot label

`state-explicit-finish-6-camera-rays`

---

## Phase D — ui.zig eager-mode + DrawList replay

**Subsystem**: `ui.zig` UI render path.  5 prod calls in 4 fns.

**Substate destination**: `UiContext` **stays in Runtime/Frame**
(for now — see "Question 2" pragmatic position).  This phase
just retires the 5 globalState reaches in the eager-mode and
deferred-replay paths by threading explicit substates through.

### The eager-mode problem

UI widgets normally record draw commands into a `DrawList`
that's replayed at frame end with explicit `gl` in scope.
But three escape hatches exist:

  - `DrawList.render` itself (line 593) — replay loop already
    has `gl` as a local; just hoist `shapes_state` once.
  - `drawTexturedQuad` eager-mode fallback (line 6833) —
    triggered when no `DrawList` is active (rare; debug paths).
  - `drawRectFilled` and `drawRect` eager-mode fallbacks
    (lines 9765, 9780-9781) — same shape.

### Decision: thread state via UiContext

Pre-plan documented two options.  Lock in option 1 (thread
into `UiContext`) — the cleanest:

```zig
pub const UiContext = struct {
    // ... existing fields ...
    gl: *rlgl.GlState,
    shapes_state: *const drawing.shapes.ShapesTextureState,
};
```

Plumbed through `UiContext.create(...)` from the caller's Frame.
Every widget that draws gets these via `ctx.gl` /
`ctx.shapes_state` instead of reaching for the global.

**Mockability payoff**: a UI test can spin up a `UiContext`
with stub gl + shapes_state and exercise widgets without a
renderer.

### Migration order

1. Extend `UiContext` definition — add the two ptr fields.
2. Update `UiContext.create` to take + store them.
3. Update Frame's UI entry point to pass `f.gl, f.shapes_texture`
   into `UiContext.create`.
4. Migrate the 5 eager-mode call sites: replace `globalX()`
   with `ctx.gl` / `ctx.shapes_state`.
5. Sweep the imgui_demo example + gallery to verify.

### Risk

The whole UI render path is exercised by imgui_demo, gallery,
and the cheatsheet HTML.  Run all three smoke tests to catch
plumbing misses.

### Snapshot label

`state-explicit-finish-7-ui-eager`

---

## Phase E — Anchor minimization + JS-bridge cleanup

**Subsystem**: `runtime_anchor.zig` + the 14 JS-bridge thunks
(input × 10, effects × 4).

### Goals (in execution order)

#### E.1 — Rename anchor

```zig
// Before
pub var anchor: ?*Runtime = null;

// After
pub var _js_bridge_anchor: ?*Runtime = null;
```

Underscore prefix is the project's convention for "internal —
don't touch from user code".  Update every reference (138
across src/) via a scripted rename.

#### E.2 — Consolidate input thunks (10 → 1)

The 10 input thunks (`pushKeyDown`, `pushKeyUp`, `pushChar`,
`pushMouseButtonDown`, `pushMouseButtonUp`, `pushMouseMove`,
`pushMouseWheel`, `pushTouchDown`, `pushTouchMove`,
`pushTouchUp`) each currently call `globalState()`.

Replace with a single named helper:

```zig
// In src/runtime.zig — input namespace.
//
// JS-bridge thunk: DOM event handlers (key, mouse, touch,
// wheel) all share this single reach into the anchor.  Each
// thunk below calls into a state-taking core fn, passing the
// result of this helper.  This is the only sanctioned anchor
// read from the input subsystem.
fn _jsBridgeInputState() *InputState {
    return &(anchor_mod._js_bridge_anchor orelse @panic(
        "Runtime not initialized — call App.create first"
    )).input;
}

// Each thunk now reads through the helper:
pub fn pushKeyDown(key: KeyboardKey, is_repeat: bool) void {
    pushKeyDownExplicit(_jsBridgeInputState(), key, is_repeat);
}
// ... and 9 more ...
```

After this step: input subsystem has 1 anchor read instead of 10.

#### E.3 — Route effects callbacks via vtable userdata (4 → 0)

The 4 `browserX` callbacks in `effects` (browserTime,
browserFrameTime, browserFps, browserEmit) currently take
`_: ?*anyopaque` (an unused userdata slot) and reach
`core.globalTime()` / `core.globalFps()` / `core.globalTracelog()`
from inside.

The vtable already has the userdata slot.  Wire `&app.runtime`
into it at clock-install time:

```zig
// At App.create time, when installing the browser clock vtable:
const browser_clock = Clock{
    .vtable = &browser_vtable,
    .userdata = @ptrCast(&app.runtime),
};

// Each callback pulls Runtime from userdata:
fn browserTime(userdata: ?*anyopaque) f64 {
    const rt: *Runtime = @ptrCast(@alignCast(userdata.?));
    return core.getTime(&rt.time);
}
```

After this step: effects subsystem has 0 anchor reads.  The
state plumbs through the existing vtable userdata channel.

**This is strictly better than a `_jsBridgeRuntime()` helper**
because it removes the global reach entirely — the vtable is
already a state-passing channel; we just stop ignoring its
userdata slot.

#### E.4 — RAF dispatch + App lifecycle

Survey what's left:

  - `App.create` — writes to `_js_bridge_anchor` (1 site, sets it).
  - `App.deinit` — writes to `_js_bridge_anchor` (1 site, clears it).
  - RAF dispatch in `zimr.zig` — reads `_js_bridge_anchor` (1 site,
    picks up `*Runtime` for `dispatchUpdate`).
  - `_jsBridgeInputState` from E.2 — reads (1 site).

Total reads: ≤ 2.  Total writes: 2 (set + clear by App).
Each commented inline with `// JS-bridge thunk: ...` rationale.

#### E.5 — Audit and verify

```bash
# Should return only the named JS-bridge sites + the var def.
grep -rn '_js_bridge_anchor' src/

# Should return 0 hits in user code.
grep -rn '_js_bridge_anchor' examples/ webtests/
```

If any user-code or example hit appears, that's a bug — fix
before declaring Phase E done.

### Phase E exit criteria

- ≤ 5 read sites of `_js_bridge_anchor` in src/, all in
  named JS-bridge thunks, each commented.
- 0 read sites in examples/ and webtests/.
- 874/874 + 90/90 green.
- `python3 scripts/count_globals.py` shows 0 production
  globalState calls across all files (the JS-bridge reaches
  no longer go through `globalState()` accessors — they go
  through `_jsBridgeInputState()` and the vtable userdata).

### Snapshot label

`state-explicit-finish-8-anchor-minimized`

---

## Done criteria — when can we declare victory?

After Phase E, verify all of:

```
[ ] python3 scripts/count_globals.py — all files show 0 prod
[ ] grep -rn 'anchor_mod\.anchor' src/ — only fn defs + named JS thunks
[ ] grep -rn '_js_bridge_anchor' examples/ webtests/ — 0 hits
[ ] zig build test — 874/874 (or higher)
[ ] zig build smoke-test — 90/90
[ ] Audio resource tables (Music, Sound, Stream, WaveAlloc)
    no longer in Runtime — moved to user State (`z.audio.State`)
[ ] All other Runtime substates retained as today; every
    fn signature documents reads/writes
[ ] CHEATSHEET.md — every public fn signature documents reads/writes
[ ] CHANGELOG.md — every phase has its turn entry
[ ] getting-started.md — opt-in pattern documented for audio
```

When the box is green: **the goal is achieved**.  Every zimr
function declares in its signature exactly which substates it
reads and which it writes.  Audio is opt-in (visible cost in
user's State definition).  Universal substates (gl, fonts,
input, time, window, shapes_texture) live in Runtime and are
reachable via Frame.

Future structural work (relocating more substates to user
State, eliminating derived substates) is **deferred** —
revisit only if a clear cost or opt-in nature emerges.

---

## Phases F + G — deferred indefinitely

Earlier turn 28 plan included two structural-cleanup phases:

- **Phase F** — Relocate `shapes_texture` + `skybox_cache`
  from Runtime to user State.
- **Phase G** — Eliminate `fps`, `tracelog`, relocate
  `gestures`.

Both are **deferred** as of turn 29.  Pragmatic position: if a
substate is universal (or close enough), it earns its Runtime
spot.  Premature relocation creates verbose State definitions
in examples for no clear benefit.

We may revisit if:

- A substate's storage cost grows meaningfully (e.g., font
  atlases beyond a single default).
- A substate's opt-in nature becomes clearer (e.g., gestures
  develops 5+ detectable patterns and only some apps want
  them).
- A new feature ships that obviously belongs in user State
  (e.g., a particle system's particle pool).

For now, only **audio resource tables** move out of Runtime.
That's the clearest opt-in case in the codebase today.

---

## After Phase E — the explicit-state endpoint

```zig
// runtime_anchor.zig — Runtime keeps universal substates +
// JS-bridge state.  Audio resource tables MOVED OUT to user
// State.
pub const Runtime = struct {
    input: input.InputState,        // JS-bridge + universal
    time: core.TimeState,           // JS-bridge + universal
    window: core.WindowState,       // JS-bridge + universal
    fps: core.FpsState,             // small derived state
    tracelog: core.TraceLogState,   // log filter
    gestures: gestures_mod.GesturesState,  // small detector state
    gl: rlgl.GlState,               // universal: every draw uses

    audio_device: AudioDeviceState, // JS-bridge

    drawing: struct {
        shapes_texture: ShapesTextureState,  // universal
        font_cache: FontCache,               // most apps draw text
        skybox_cache: SkyboxCache,           // small cost; stays for now
    },
};
// ~10 substates.  Down from 13 today; the four audio tables
// (music/sounds/streams/waves) moved to user State.

// zimr.zig — Frame is stable post-Phase-D:
pub const Frame = struct {
    gpa: Allocator,
    scratch: Allocator,
    loader: Loader,
    clock: Clock,
    rng: Rng,
    log: Logger,

    input: *const InputState,
    window: *const WindowState,
    gl: *GlState,
    shapes_texture: *const ShapesTextureState,
    font_cache: *FontCache,         // added in B.3
    skybox_cache: *SkyboxCache,
    ui: Ui,
};
// ~13 fields.  Adding a new universal feature would add a
// field; adding an opt-in feature wouldn't.
```

User's State holds opt-in feature pools (currently just
audio):

```zig
const State = struct {
    audio: z.audio.State,    // bundles MusicTable + SoundTable + StreamTable + WaveAllocTable
    bgm: z.audio.Music,
    // ...rest is the user's own data...
};
```

---

## (Deferred) potential future work

These are nice-to-haves the foundation enables.

- **Hot reload** — see `hotreload-design.md`.  Foundation in
  place; user provides serialize/deserialize for their State.
  **No longer a goal.**
- **Dual renderer** — software-rendered backend alongside
  WebGL for visual regression testing.  Each example runs
  both, bytewise compare framebuffers.  Trivial once
  `*GlState` is threaded explicitly (already true post-D).
- **Audio recording sink** — the `AudioDeviceState` interface
  could grow a "record to WAV" backend used by audio examples
  for snapshot tests.

---

## Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| Cross-fn cascade balloons mid-turn | Medium | Lesson #11: commit the whole cascade in one batch when ≤ 3 fns; document scarlet letter when > 3. |
| Test fixture removal hides a transitive `defer` reach | Medium | Lesson #13: trace `defer` chains in step 4 of per-fn workflow. |
| Disk fills mid-build | Low | Lesson #9: `rm -rf .zig-cache zig-out` and retry. |
| Frame grows with feature-specific state | Medium | Rule 3 in §"Why we are doing this" — new feature ≠ new Frame field unless universal. |
| Phase E vtable-userdata doesn't compile cleanly | Low | Fall back to `_jsBridgeRuntime()` helper; same end-state count. |
| Hidden anchor reach in seemingly-pure fn | Medium | Per-fn workflow step 2 (read end-to-end) catches this; build verify catches the rest. |
| Per-call lens applied wrongly to genuinely shared state | Low | Decision criteria in §"Design principles". |
| **Audio user-State sweep** explodes State definitions in 8+ audio examples | Medium | Each Phase C subphase migrates one audio family at a time; build verify between batches.  `z.audio.State` bundles four tables into one field so the State growth is bounded (1 field per audio-using app). |
| **User confusion** — "why does my State need a `z.audio.State` field?" | Low | Document opt-in pattern clearly in `getting-started.md`; the verbose State definition is the *point* — feature cost is visible. |
| **Examples grow verbose** — every shape draw threads `f.gl, f.shapes_texture` | Confirmed | Documented non-goal: ergonomics is not the priority.  After endpoint, evaluate whether a Frame-method convenience layer is worth adding. |
| Audio-device-decode JS callback can't find AudioDeviceState | Low | `AudioDeviceState` *stays* in Runtime per Phase C4; never moves to user State.  Same anchor reach as today. |

---

## Appendix — the audit script

`scripts/count_globals.py`.  Run at the start of every turn to
refresh metrics, and re-run after the migration to verify the
count went down by exactly the expected amount.

```python
import re
from pathlib import Path

def analyze(path):
    text = path.read_text()
    lines = text.split('\n')
    fn_decls = []
    fn_re = re.compile(r'^(\s*)(pub (inline )?)?fn (\w+)\s*\(')
    test_re = re.compile(r'^(\s*)test\s+"([^"]+)"\s*\{')
    for i, line in enumerate(lines):
        m = fn_re.match(line)
        if m:
            fn_decls.append((i, m.group(4), False))
            continue
        m2 = test_re.match(line)
        if m2:
            fn_decls.append((i, 'test', True))
    call_re = re.compile(r'global[A-Z][a-zA-Z]*\(\)')
    fn_def_re = re.compile(r'pub (inline )?fn global[A-Z]|^\s*fn global[A-Z]')
    prod = test = 0
    for i, line in enumerate(lines):
        s = line.lstrip()
        if s.startswith('///') or (s.startswith('//') and not s.startswith('///')):
            continue
        if not call_re.search(line) or fn_def_re.search(line):
            continue
        if 'anchor_mod.anchor' in line:
            continue
        enc = None
        for ln, nm, t in fn_decls:
            if ln <= i: enc = (nm, t)
            else: break
        if enc and enc[1]: test += 1
        elif enc: prod += 1
    fix = sum(1 for line in lines if 'anchor_mod.anchor = &rt;' in line)
    return prod, test, fix
```

(Full script in `scripts/count_globals.py`.)

---

*End of plan.  Phase B is the first turn after this one.*
