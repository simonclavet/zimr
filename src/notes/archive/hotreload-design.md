# Hot reload — design memo

*Written turn 26 as a brainstorm during the no-globals work.
Captures the design constraints we've locked in before Phase F
implementation begins.  Sister docs: `archive/state-explicit-plan.md`
(the original architecture's persist/drop split table),
`archive/state-explicit-finish-plan.md` (the now-completed plan
that took every fn state-explicit; that work was the hot-reload
prep — globals are now zero, see `dag-plan.md` archive).*

---

## Goal

When the user changes their code, swap to the new wasm module
*without re-running `initState`*.  Specifically: don't refetch
the 50 MB asset that took 200 frames to load.  Don't re-decode
audio.  Don't re-bake font atlases.

The point of hot reload is preserving the work — both the
loaded resources (which mostly live in JS land already) and
the user's State (which lives in wasm linear memory and dies
with the old module).

## Locked-in constraints (turn 26)

We accept simplifications that make hot reload tractable
without exotic comptime machinery:

1. **User's `State` cannot contain internal pointers.**  Only
   plain data: integers, floats, fixed-size arrays, slices into
   user-allocated buffers (the slice itself is a pointer + len,
   so even slices need user-supplied serialization), enums,
   c_uint resource handles (texture IDs, audio buffer IDs,
   loader handles).
   - **Why**: pointers into wasm linear memory die when the old
     wasm tears down.  The new wasm's memory is empty; the old
     pointer is meaningless.
   - **Consequence**: users design State around handles + IDs
     (as zimr already does with textures, sounds, etc.) rather
     than nested struct pointers.  Zig idiom anyway.
   - **Allowed exception**: pointers to *static / comptime*
     const data are reconstructible by re-running the same
     declaration in the new wasm.  Users keep these out of
     State or accept they'll point to the new wasm's copy.

2. **Users provide `serialize` / `deserialize` for their
   State.**  No comptime reflection magic.  The user types two
   functions:

   ```zig
   pub fn serialize(state: *const State, gpa: Allocator) ![]u8;
   pub fn deserialize(bytes: []const u8, gpa: Allocator) !State;
   ```

   - For plain-data States, `std.json.stringifyAlloc` and
     `std.json.parseFromSlice` are one-liners.  Most users do
     literally that.
   - For States with custom behavior (lookup tables, decoded
     handles), the user has full control.
   - The framework calls these at the right moments; no magic.

3. **Hot reload is not 100% reliable.**  Failure modes are
   acceptable:
   - In-flight loader fetches → either the loader's table is
     JS-owned (works) or the reload fails cleanly and the user
     starts cold.
   - Audio sources currently playing → reload pauses them; user
     code restarts playback if it cared.
   - User's `serialize`/`deserialize` raises an error → fall
     back to cold start with a JS-side log.
   - Type changes in `State` between code versions → user is
     responsible for handling version migration in their
     `deserialize` (or accepting the cold-start fallback).

   The contract: hot reload is a *best-effort optimization*,
   not a guarantee.  When it works, it's instant.  When it
   doesn't, you fall back to cold start (same as F5 today).

## What survives a wasm tear-down

Things outside wasm survive automatically.  Things inside wasm
die unless serialized.

| Class | Lives where | Reload behavior |
|---|---|---|
| WebGL texture objects | GL context (JS) | survives — texture IDs in user State are still valid |
| WebAudio buffers | AudioContext (JS) | survives — buffer IDs in slot tables are still valid |
| WebAudio sources (currently playing) | AudioContext (JS) | survives but disconnected; user code can re-issue play if needed |
| Fetch promises in flight | JS Promise queue | survives — loader handles still resolve |
| Canvas dims, audio context handle | JS DOM/AudioContext | reconstruct from JS at restore |
| User's `State` (fields with no pointers) | wasm linear memory | dies; restored via user's `deserialize` |
| Runtime slot tables (`MusicTable.entries[]` etc.) | wasm linear memory | dies; restored via framework `dumpForReload`/`restoreFromReload` |
| `Runtime.gl` (matrix stack, batch) | wasm linear memory | dies; defaults to fresh `GlState{}` (correct — per-frame anyway) |
| `Runtime.drawing.default_font` (atlas + glyph data) | wasm linear memory | dies; lazy-rebuilds on first use after reload |
| `Runtime.input` (event snapshots) | wasm linear memory | dies; next frame's events repopulate |
| `Runtime.time` (frame_index, dt) | wasm linear memory | partial — wall-clock offset preserved, frame_index resets to 0 |

## API shape

### User-facing

```zig
// One init signature.  `persisted: ?[]const u8` is null on cold
// start, non-null when JS has reload bytes from the previous
// wasm instance.
fn initState(
    f: *Frame,
    persisted: ?[]const u8,
) !State {
    if (persisted) |bytes| {
        // Hot-reload path.  User-provided deserialize.  If this
        // throws, the framework catches and falls back to cold
        // start.
        return State.deserialize(bytes, f.gpa);
    }

    // Cold-start path.  Fire fetches, set up State, etc.
    return .{
        .tex_handle = f.loader.loadFileData("big_image.png"),
        // ...
    };
}

// User's serialize fn.  Framework calls before tear-down.
pub fn serialize(
    state: *const State,
    gpa: std.mem.Allocator,
) ![]u8 {
    return std.json.stringifyAlloc(gpa, state, .{});
}

pub fn deserialize(
    bytes: []const u8,
    gpa: std.mem.Allocator,
) !State {
    const parsed = try std.json.parseFromSlice(State, gpa, bytes, .{});
    defer parsed.deinit();
    return parsed.value;
}
```

The user wires these into `z.run`'s options:

```zig
z.run(
    .{ .window = .{...} },
    State,
    initState,
    update,
    .{
        .serialize = State.serialize,        // optional
        .deserialize = State.deserialize,    // optional
    },
) catch |err| { ... };
```

When both `serialize` and `deserialize` are provided, hot
reload is enabled.  Either missing → reload becomes cold start.

### Framework-facing

`Runtime` gains two methods:

```zig
/// Serialize the persistent subset of Runtime substates plus
/// the user's State (via the user-supplied serialize fn) into
/// a single byte blob.  The framework owns the byte format.
pub fn dumpForReload(
    self: *Runtime,
    user_state_serialize_fn: *const fn (*const anyopaque, Allocator) anyerror![]u8,
    user_state_ptr: *const anyopaque,
    gpa: Allocator,
) ![]u8;

/// Inverse: populate Runtime's persistent fields from bytes,
/// zero-init transient fields, return the deserialized user State.
pub fn restoreFromReload(
    self: *Runtime,
    bytes: []const u8,
    user_state_deserialize_fn: *const fn ([]const u8, Allocator) anyerror!*anyopaque,
    gpa: Allocator,
) !*anyopaque;
```

These are called by the JS bridge (Phase G) — not user code.

## Persist / Transient split per substate

Each substate annotates its fields.  Implementation: a
namespace-level constant `pub const _persist_fields = ...;` or a
sub-struct split (`Persistent` / `Transient`).  The
`dumpForReload` walker reads the annotations.

Per the original architecture (refined):

| Substate | Persist | Transient | Reconstruct |
|---|---|---|---|
| `MusicTable.entries[].buffer_id` | ✅ | | |
| `MusicTable.entries[].playback_state` | partial — preserve loop flag, drop in-flight source ID | | |
| `SoundTable.entries[]` | same shape as Music | | |
| `StreamTable.entries[]` | same | | |
| `WaveAllocTable.entries[]` | wave handle table — preserve | | |
| `Runtime.gl.{matrices, batch}` | | ✅ | fresh |
| `Runtime.input` | | ✅ | next frame |
| `Runtime.time.t_offset` | partial | | wall-clock preserves; frame_index resets |
| `Runtime.fps` | | ✅ | recomputes |
| `Runtime.drawing.shapes_texture` | | ✅ | default 1×1 white |
| `Runtime.drawing.default_font` | | ✅ | lazy-rebuild |
| `Runtime.window` | | | reconstruct from JS at restore |
| `Runtime.audio.device` | | | reconstruct from JS (AudioContext id) |

## Failure modes (and the contract they imply)

| Failure | Behavior |
|---|---|
| `serialize` throws | reload fails; JS logs; cold start |
| `deserialize` throws | reload fails; JS logs; cold start |
| State type changed incompatibly | user's `deserialize` throws on bad version → cold start |
| In-flight loader fetch | loader table JS-owned → fetch survives; if not, user's State has a stale handle and `pollFileData` returns an error → user falls back |
| Audio source playing | source disconnects; metadata in slot table preserves loop flag etc.; user code can re-issue `play` if it cared |
| Wasm linker error | new module fails to instantiate → JS keeps old module alive (no swap performed) |

The pattern: when something can't be preserved cleanly, **fail
loudly and fall back to cold start**.  Hot reload is opt-in
fast-path; cold start is the always-works baseline.

## Implications for current work

**Phase B (no-globals in drawing.zig)**: nothing changes.  The
explicit-state work IS the hot-reload prep work.

**Phase C (sound.zig migration)**: design slot tables with the
serialization end-state in mind:

  - `MusicTable.entries[i]: MusicEntry` — keep `MusicEntry` as
    plain-data (handle + flags + counters; no pointers).
  - Same for `SoundTable`, `StreamTable`, `WaveAllocTable`.

The state-explicit migration produces this naturally — every fn
declaring its substate access discourages internal pointers.

**Phase F (when we land hot reload)**:

  1. **Loader refactor** — move pending-fetch tracking fully to
     JS so the wasm loader becomes stateless about fetches.
     (Independent prerequisite.)
  2. **Annotate Persistent/Transient** on each substate.
  3. **Implement `dumpForReload` / `restoreFromReload`** — walks
     annotated fields, calls into user's serialize/deserialize
     for State.
  4. **Add `persisted: ?[]const u8` parameter** to `initState`.
  5. **Add `serialize`/`deserialize` slots** to z.run options.
  6. **Round-trip tests** — dump → restore → observable behavior
     matches (tested via stable user States).

**Phase G (the JS bridge)**:

  1. **Trigger** — button, filesystem watcher, or postMessage.
  2. **Dump** — JS calls exported `world_dump()` → bytes.
  3. **Tear down** — release the old wasm instance.
  4. **Instantiate** new module — fresh wasm.
  5. **Restore** — JS calls exported `world_restore(bytes)` →
     populates Runtime + invokes user's deserialize → resumes RAF.
  6. **Failure handling** — on any error, log, fall back to cold
     start.

## What we don't decide today

- **Wire format** of the dump bytes.  zon? json? custom?  Defer
  to Phase F implementation.
- **Versioning** of dump format across zimr versions.  Probably
  a magic-bytes header + version u32, but defer.
- **Multi-instance reload** (multiple canvases on one page).
  Future concern.
- **Time-travel debugging** (snapshot history, scrub backward).
  Far future.

## Why this works

The explicit-state architecture's payoffs (read/write clarity,
mockability, backend swap) all align with hot reload's needs:

  - **Read/write clarity** → easy to mark which fields persist.
  - **Mockability** → tests construct Runtime instances directly,
    so dumping + restoring is just round-tripping a struct.
  - **Backend swap** → the audio backend, GL backend, etc. all
    reconnect to the same JS-side resources after reload because
    we treat them as configurable substates.

Without explicit state, hot reload is a black-box "everything
might be a problem" — pointers could lurk anywhere.  With
explicit state, each migration explicitly removes
hot-reload-hostile constructs (internal pointers, captured
closures).  Phase F's work is small precisely because the
foundation is good.
