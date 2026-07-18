# state-explicit refactor — plan

## Goal

Eliminate module-level state. Every fn's signature documents its
reads/writes by taking explicit subsystem-state pointers.

## Discipline (non-negotiable)

1. **No fn takes the whole `Frame`.** A fn that needs `gl` + `time`
   takes `gl: *GlState, time: *const TimeState`. If a fn legitimately
   needs five subsystems, that's signal it's doing too much, not signal
   to take the whole bundle.
2. **One residual global.** Exactly one `var anchor: ?*Runtime = null;`
   at the JS bridge layer, so JS-fired exports can find the world.
   Documented; everything else is explicit.
3. **Const-correctness is documentation.** `*const InputState` reads,
   `*InputState` mutates. Every fn declares which.
4. **Method syntax is taste, not policy.** `gl.rlBegin(mode)` and
   `rlgl.rlBegin(gl, mode)` are the same fn. Pick locally. The
   constraint is on what's *threaded*, not on call-site syntax.

## Top-level types

```zig
// Long-lived. One per (canvas + GL ctx + audio ctx). Owned by host.
pub const Runtime = struct {
    gpa: std.mem.Allocator,
    gl: GlState,
    window: WindowState,
    time: TimeState,
    fps: FpsState,
    input: InputState,
    web: WebBridgeState,
    audio: AudioState,
    log: Logger,         // already vtable
    loader: Loader,      // already vtable
    rng: Rng,            // already vtable
    clock: Clock,        // already vtable
    assets: AssetRegistry,
    drawing: DrawingState,  // bundles ShapesTexture, FontDefaults, SkyboxCache

    pub fn init(gpa: std.mem.Allocator) !Runtime;
    pub fn deinit(self: *Runtime) void;
};

// Per-tick borrow bundle. Owns nothing.
pub const Frame = struct {
    gpa: std.mem.Allocator,
    scratch: *std.heap.ArenaAllocator,
    gl: *GlState,
    window: *const WindowState,
    time: *const TimeState,
    input: *const InputState,
    log: Logger,
    dt: f32,
    frame_index: u64,
};

pub fn beginFrame(rt: *Runtime, scratch: *std.heap.ArenaAllocator) Frame;
```

User code (the only place a whole `Frame` appears):

```zig
pub fn update(frame: *Frame) void {
    if (input.isKeyPressed(frame.input, .space)) {
        spawnEnemy(frame.gl, frame.gpa);
    }
    drawing.shapes.drawRect(frame.gl, .{ ... }, .red);
}
```

Everything below `update` takes subsystem ptrs only.

## Signature examples (the discipline in action)

```zig
isKeyDown(input: *const InputState, key: KeyboardKey) bool
getTime(time: *const TimeState) f64
setTargetFPS(time: *TimeState, fps: c_int) void
beginFrame(time: *TimeState, fps: *FpsState, input: *InputState, web: *WebBridgeState) void

rlMatrixMode(gl: *GlState, mode: c_int) void
rlPushMatrix(gl: *GlState) void
rlBegin(gl: *GlState, mode: c_int) void
rlVertex2f(gl: *GlState, x: f32, y: f32) void

drawRect(gl: *GlState, rect: Rectangle, color: Color) void
loadTexture(gpa: Allocator, gl: *GlState, assets: *AssetRegistry, image: Image) !Texture
traceLog(log: Logger, level: Level, comptime fmt: []const u8, args: anytype) void
```

## Phased plan

Every phase ends with 874/874 + 90/90 green. Snapshot before each
phase. No half-migrated state at phase boundaries.

### Phase 0 — Inventory (1 session)

Scripted sweep: `grep -nE '^(pub )?var '`, `grep -n 'comptime { _ = '`,
`grep -nE '_test_(Reset|Get|Set)'`. Per global: who reads, who writes.
Output: `src/notes/state-explicit-inventory.md` with every global
tagged by subsystem + caller count.

**Exit:** no build changes; we have a budget.

### Phase 1 — Define State structs (3-4 sessions)

For each subsystem, hoist its module-level state into
`pub const <Name>State = struct { ... }`. The struct is just *defined*
at this point — module-level vars still exist, code path unchanged.

- **1a.** `InputState` (most isolated; sets the pattern)
- **1b.** Split `core` into `TimeState`, `WindowState`, `FpsState`
  (was always three things)
- **1c.** Audit `gestures`, `camera` — probably stateless, skip
- **1d.** `GlState` (the big definition; pure naming)
- **1e.** `ShapesTextureState`, `FontDefaults`, `SkyboxCache`,
  aggregated as `DrawingState`
- **1f.** `WebBridgeState`, `AudioState`

**Exit:** all State types defined; tests pass; no signatures changed.

### Phase 2 — Runtime + Frame skeleton (1 session)

Aggregate the State types into `Runtime`. Define `Frame`. Add
`Runtime.init/deinit/beginFrame`. Add the documented anchor:
`var anchor: ?*Runtime = null;`. Nothing wired up yet.

**Exit:** types compile; tests pass.

### Phase 3 — Migrate subsystems (transactional, one at a time)

For each subsystem:

1. Change every fn signature to take `*<Name>State` as first arg.
2. Update every caller to pass the ptr — from `&anchor.?.X` for
   JS-fired exports, from `frame.X` elsewhere.
3. Delete the module-level `var`.
4. Delete `_testReset` / `_testGetX` accessors — tests now own a
   fresh State directly.
5. Update tests: `var input: InputState = .{};` instead of
   `_testReset()`.
6. Remove the subsystem from any `comptime { _ = X; }` block (tests
   now reachable via Runtime).
7. Tests pass before moving to next subsystem.

Order (least to most callers):

| Step | Subsystem | Caller surface | Sessions |
|---|---|---|---:|
| 3a | `input` | input.zig + ~10 ui.zig + apps | 1 |
| 3b | `time`, `window`, `fps` | ~30 across runtime + drawing + ui | 1-2 |
| 3c | `gestures`, drawing internals | small islands | 1 |
| 3d | `web`, `audio` | bridge plumbing | 1 |
| 3e | `gl` (rlgl) | drawing.zig everywhere | 3-4 |
| 3f | `assets` | drawing.zig | 1 |

**3e** broken down further (it's the boss fight):
- 3e.i: keep old module-level fns alive as thin wrappers around
  `(gl, ...)` versions
- 3e.ii: migrate rlgl.zig internals (RLGL.X → gl.X)
- 3e.iii-v: migrate drawing.shapes, drawing.textures, drawing.text,
  drawing.models, drawing.shaders
- 3e.vi: delete the wrappers + the old `RLGL` instance

**Exit per step:** subsystem has zero module-level vars; tests pass.

### Phase 4 — Anchor audit (1 session)

Count JS-bridge thunks that reach into `anchor`. Should be small (one
per dom event type, one per audio callback). Document each at the
anchor declaration site as the deliberate boundary.

**Exit:** the residual global is minimal + documented.

### Phase 5 — Selective serialization (2 sessions)

Per-subsystem decision (matches the insight that most state doesn't
need to survive reload):

| Subsystem | Reload behavior |
|---|---|
| game state, `assets` | **persist** (zon round-trip) |
| `time` | partial — wall-clock offset persists, frame counter resets |
| `gl`, `input`, `fps`, `scratch`, `web` | **drop** (rebuild fresh) |
| `window`, `audio` | **reconstruct from JS** (canvas size, audio ctx ID) |

Implementation: split mixed structs into `.Persistent` / `.Transient`
sub-structs. `Runtime.dumpForReload(gpa) ![]u8` walks only persistent
fields. `Runtime.restoreFromReload(bytes) !void` populates them and
zero-inits the rest.

Add tests: per-subsystem round-trip + top-level
dump-restore-compare.

**Exit:** round-trip works; transient subsystems explicitly excluded.

### Phase 6 — JS bridge reload (2 sessions)

JS side: button/watcher → `world_dump` → tear down → re-instantiate
→ `world_restore` → resume RAF. JS-side input queue survives the
swap because it lives in JS, not linear memory.

**Exit:** end-to-end reload preserves the persistent subset.

## Decisions locked in

1. **Names:** `Runtime`, `Frame`. Subsystem types end in `State`.
   (Existing effect handles `Logger`/`Loader`/`Rng`/`Clock` keep their
   names.)
2. **Fn signatures:** subsystem ptr only. Never `*Frame` or `*Runtime`.
3. **Allocator:** `std.mem.Allocator` as Zig stdlib idiom. Per-frame
   scratch via `*ArenaAllocator` reset each tick.
4. **JS anchor:** exactly one `var anchor: ?*Runtime`, documented at
   declaration site.
5. **Serialization split:** `.Persistent` / `.Transient` sub-structs
   where mixed. Default-skip until opt-in.
6. **Method syntax:** allowed but unprefereed. `mod.fn(state, args)`
   is more honest than `state.fn(args)`.

## Open questions (decide on the way)

- Asset registry layout: handle table or arena? Doesn't block until
  Phase 3f.
- Multi-runtime (multiple canvases)? Not required today. Keep `anchor`
  as a single ptr; widen to slice if it matters.
- Keep `pub const X = struct {}` wrapper namespaces in runtime.zig /
  drawing.zig, or flatten? Lean: keep — they're documentation of
  subsystem boundaries even after state moves out.

## Total scope

~15-20 sessions if rlgl behaves. Comparable mechanical effort to the
test relocation, with deeper design choices per step. Each phase
shippable independently — at any phase boundary the codebase is fully
working, just less explicit than the next phase.
