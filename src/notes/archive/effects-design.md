# Effects design

How zimr handles side-effects (loading, time, randomness, logging) so
that they're explicit at the call site, swappable for tests, and don't
require any global state.

## The four effect types

| Type | Purpose | Methods |
|---|---|---|
| `Loader` | Async asset loading | `loadFileData`, `pollFileData`, `unloadFileData`, `elapsedMs` |
| `Clock` | Time | `time`, `frameTime`, `fps`, `wallMs` |
| `Rng` | Randomness | `value(min, max)`, `seed`, `float01`, `bytes`, `boolean` |
| `Logger` | Log emission | `trace`, `debug`, `info`, `warn`, `err`, `fatal` |

Each is a 16-byte value type (`{ userdata, vtable }`).  Each has a
production impl (`Browser`) and a deterministic test impl (`Mock` for
Loader/Clock, `Seeded` for Rng, `Capture` for Logger).

All four sit on `Frame` next to the existing allocator fields:

```zig
pub const Frame = struct {
    app: *App,
    gpa, frame, scratch: std.mem.Allocator,
    loader: Loader,
    clock: Clock,
    rng: Rng,
    log: Logger,
};
```

## Method names mirror raylib

The point is to keep raylib veterans at home.  Where raylib has a
function, our method name matches:

| raylib | zimr |
|---|---|
| `GetTime()` | `f.clock.time()` |
| `GetFrameTime()` | `f.clock.frameTime()` |
| `GetFPS()` | `f.clock.fps()` |
| `GetRandomValue(min, max)` | `f.rng.value(min, max)` |
| `SetRandomSeed(seed)` | `f.rng.seed(seed)` |
| `LoadFileData(path)` | `f.loader.loadFileData(path)` * |
| `UnloadFileData(data)` | `f.loader.unloadFileData(handle)` |
| `TraceLog(LOG_INFO, fmt, ...)` | `f.log.info(fmt, .{...})` |

\* `loadFileData` returns a `Handle`, not bytes.  The bytes show up
on a later frame — call `pollFileData(handle)` to check.  The
asynchrony is unavoidable: browsers don't allow blocking.

## Why no globals?

Three reasons.

**Mocking is uniform.**  Every effect goes through `Frame`; tests
override via `App.setLoader` / `setClock` / `setRng` / `setLogger`.
With globals, mocking RNG would need a global swap, mocking time
would need a different one, and so on — each ad-hoc.

**Smaller functions take exactly what they need.**  A particle update
fn takes `Rng`, period:

```zig
fn updateParticles(rng: Rng, particles: *Particles) void { ... }
```

The signature documents what the function touches.  No "global
something" hidden in the body.

**One canonical way.**  `f.clock.frameTime()` and only
`f.clock.frameTime()`.  No `z.getFrameTime()` that does the same
thing as a free function (we deleted those — the underlying
`core.zig` functions are still there but are documented as internal,
called only by the `Browser` impls).

## What about init code that runs before `App.start`?

Two options:

1. **Defer to the first frame** — set state in `update` when
   `frame_count == 1`.  This is what `examples/particles.zig` does
   for its `f.rng.seed(...)` call.
2. **Use `std.debug.print`** for one-shot init logging.  This is what
   `examples/png_demo.zig` does.  No Frame yet → no Logger; falling
   back to stdlib is honest.

Don't reach into `core.traceLog` directly — it's there for the
`Logger.Browser` impl, not for user code.

## Mocking

```zig
test "particle spawn rate is ~5%" {
    var rng = Rng.Seeded.init(42);
    var clock = Clock.Mock.init(.{ .frameTime = 1.0 / 60.0 });
    var loader = Loader.Mock.init();
    defer loader.deinit(ta);
    var capture = Logger.Capture.init(ta);
    defer capture.deinit();

    app.setRng(rng.rng());
    app.setClock(clock.clock());
    app.setLoader(loader.loader());
    app.setLogger(capture.logger());

    // Drive 1000 simulated frames; assert spawn count is in the
    // expected ~5% band.
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        clock.advance(1.0 / 60.0);
        // ... call user update ...
    }
    try expect(state.spawn_count > 40 and state.spawn_count < 60);
}
```

Each axis is independent.  Want deterministic RNG with real time?
Just set Rng.  Want to assert a log line was emitted on a
specific frame?  Just set Logger.

## Why JSPI doesn't change this

Earlier sessions explored using `std.Io` and JSPI for fully-synchronous
asset loading.  The conclusion (April 2026): **JSPI ships in Chrome
137+ by default but is flagged in Firefox 139 and only in Safari TP**.
Locking v0.1 onto JSPI would lose real users.

When JSPI is universal (likely 2027+), `Loader` doesn't have to
change.  We'd have two options:

1. Keep `Loader` poll-based forever; the underlying `web/fetch.zig`
   still works the same way.  No churn.
2. Add a *new* synchronous loader type (`SyncLoader`?) for code that
   wants to write `const bytes = sloader.loadFileData("img.png")`
   straight-line.  Apps that want it opt in; existing code keeps
   working.

Either way `Loader` as it exists today is forward-compatible.

## Non-goals

- **Not** a general async runtime.  No futures, no green threads, no
  event loop.  zimr is single-threaded, frame-pinned.
- **Not** a polyfill for `std.Io`.  We don't try to make `Clock.time()`
  compatible with `std.Io.Clock.now()` — different shapes, different
  audiences.
- **Not** a wrapper around every browser API.  No localStorage,
  IndexedDB, WebSockets, Bluetooth.  We add slots when zimr itself
  has a use case.

## When to add a new effect type

A new top-level Frame field makes sense when:

1. **At least one zimr module needs it.**
2. **It's a real effect** (touches the outside world: time, RNG, IO,
   sound, network) — pure-CPU helpers don't need a Frame field.
3. **It can be mocked.**  If the impl is so tied to JS APIs that no
   sensible deterministic version exists, the surface goes through
   `dom.zig` directly without joining the effect family.

Likely future additions: `Audio` (when Phase 9 ships proper sound
playback) and `Input` (the existing snapshot-based input could be
wrapped, though most callers don't need to mock input).

Less likely additions: `Clipboard`, `Storage`.  Speculative until
asked for.
