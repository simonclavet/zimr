# Phase 12 — The Grand Ziggification — Detailed Plan

The C-ABI port is functionally complete enough for real demos.  Phase 12
is where zimr stops being "raylib in Zig" and becomes a Zig library.

## Framing

The C ABI in the current codebase is **scaffolding from the porting
process**, not a feature.  When phases 1-9 mirrored raylib's C
signatures, every internal fn became `pub export fn ... callconv(.c)`.
There is no actual C consumer.  Nothing in the system needs
`DrawRectangle`, `BeginMode3D`, `colorLerp`, `vector2Add`, etc. to be
wasm exports or use C calling conventions.  Those fns are called only
from Zig (the examples).

Phase 12 deletes the C-shaped surface entirely.  The new public API is
Zig-idiomatic: error unions, slices, methods, allocator-explicit,
camelCase.  PascalCase aliases are deleted, not deprecated — examples
get updated in the same session that drops them.

## Anchor: the target API

The user's design sketch from the project's first session:

```zig
pub fn main(init: std.process.Init) !void {
    var app = try z.init(.{ .gpa = init.gpa, .io = init.io,
        .window = .{ .title = "zimr v0.1: Pure Zig" } });

    const state = try init.gpa.create(AppState);
    state.* = .{
        .runtime = app,
        .tex = try z.loadTexture(init.gpa, "zig_logo.png"),
        ...
    };

    try init.runtime.start(.{ .state = state, .update = update });
}

fn update(f: *z.Frame, state: *AppState) !void {
    f.clear(z.colors.slate_900);
    state.tex.draw(.{ .x = 100, .y = 100 }, .white);

    if (f.input.isKeyPressed(.space)) state.paused = !state.paused;
    const mouse = f.input.mousePos;
    if (mouse.distanceTo(state.center) < 50) { ... }
}
```

The sketch above mixes call styles (`f.clear(...)` method-style;
`z.colors.slate_900` namespaced).  Per the style guide below, this is
fine — the call site picks what reads best.  Both `f.clear(color)` and
`Frame.clear(f, color)` produce identical compiled code.

## Style guide: methods vs free functions

Both calling styles work in Zig from the same declaration:

```zig
// Defined inside Vector2:
pub fn add(a: Vector2, b: Vector2) Vector2 { ... }

// Called either way — identical compiled code:
const c1 = Vector2.add(a, b);   // namespaced free fn
const c2 = a.add(b);            // method syntax
```

The plan does NOT pick a winner.  Both styles coexist; the call site
chooses what reads best.  Pragmatic guidance:

**Prefer namespaced** (`Vector2.add(a, b)`) when:
- Operation is symmetric — neither argument is "the receiver"
  (`add`, `lerp`, `intersection`, `cross`)
- Reader benefits from seeing the type up-front
- We're documenting / introducing the API in tutorials

**Prefer method syntax** (`tex.deinit()`, `f.clear(color)`) when:
- One argument is genuinely the receiver (`deinit`, `draw onto this
  thing`, `update this state`)
- The operation matches Zig stdlib idioms (`list.append`,
  `file.close`, `allocator.create`)
- It reads more naturally at the call site

**Examples won't be uniform.**  `Vector2.add(a, b)` and `f.clear(color)`
will appear in the same example file.  That's fine — Zig's call-site
resolution makes both unambiguous, and stylistic uniformity-for-its-
own-sake is worth less than per-call-site clarity.

This is more pragmatic than the original sketch, which leaned heavily
on method chains (`f.input.isKeyPressed(.space).onPress(...)` style).
We're not building an OOP library — we're building Zig functions that
happen to be organized into per-type namespaces.

---



After Phase 12, the only `pub export fn` decorations left are functions
JS actually calls.  Roughly 10 entries:

- **Lifecycle**: `zimr_frame` (per-rAF tick), `zimr_init` (init hook), `_initialize` (auto), the user `main`
- **Asset bridge**: `zimr_fetch_alloc`, `zimr_fetch_free` (JS allocates buffers in wasm linear memory when fetch resolves)
- **Input event injectors**: `input_push_key_down/up`, `input_push_mouse_button_down/up`, `input_push_mouse_move`, `input_push_mouse_wheel`

Everything else loses `pub export fn` and `callconv(.c)`.  The wasm
export table goes from ~300 entries to ~10.  Estimated wasm size
savings: 5-10% per binary (basic.wasm at 76 KB might drop to 70 KB).

## Sub-phase ordering rationale

Each sub-phase ends with `zig build test` + smoke green.  Bottom-up
by dependency:

```
12.0  C-ABI decoration removal      (this turn — pure mechanical)
                ↓
12.1  Type-namespaced functions     (Vector2.add, Color.lerp, Rectangle.contains)
                ↓
12.2  Resource type APIs            (tex.deinit / Texture.deinit, draw, etc.)
                ↓
12.3  Error unions                  (loadTexture → Error!Texture)
                ↓
12.4  PascalCase → camelCase rename (DrawRectangle → drawRectangle)
                ↓
12.5  Capability passing            (`std.Io` adoption, `BrowserIo`, Frame-as-Io)
                ↓
12.6  App entry redesign            (z.init takes .gpa + .io explicitly)
                ↓
12.7  Port remaining env imports    (uploadMesh / unloadShader / loadImageColors / getRandomValue)
                ↓
12.8  Examples migration            (rewrite all 8 examples)
```

12.0 is happening now (this session).  See `ZIGGIFY_NOTES.md` Session
N+13 for the audit and execution log.

## Sub-phase 12.0 — C-ABI decoration removal (this session)

**Goal:** strip `pub export fn` and `callconv(.c)` from every fn called
only from Zig.  Keep the ~10 JS-called exports.  No semantic change,
no naming change, no API surface change yet.

### Strategy
- Find all `pub export fn` decls.  Categorize:
  - **JS-callable** (preserved): zimr_frame, zimr_init, zimr_fetch_*,
    input_push_*, _initialize, main
  - **Internal** (converted to `pub fn`): everything else
- Mechanical sed across the source tree.  Verify wasm export table
  shrunk to ~10 entries per binary.  Verify all tests + smoke pass.

### Definition of done
- `pub export fn` count in src/ matches the JS-callable allowlist exactly
- Wasm export table in basic.wasm has ~10 entries (vs ~300 today)
- 243 host tests + 8 smoke still green
- Wasm sizes dropped by 5-10% across all examples

### What we're NOT doing in 12.0
- No PascalCase → camelCase renames (12.4)
- No `c_int`/`c_uint`/`[*c]T` to Zig types — leave for 12.1+
- No method APIs — leave for 12.1
- No error unions — leave for 12.3
- No new functionality

12.0 is purely about removing decorations that were inherited from the
raylib-port phase.  It's a one-session pass that makes every subsequent
sub-phase easier (less noise to skim past, less ABI rigidity).

## Sub-phase 12.1 — Type-namespaced functions

**Goal:** `Vector2`, `Vector3`, `Vector4`, `Matrix`, `Color`, `Rectangle`
gain `pub fn` declarations inside the type's namespace.  Callable both
ways (`Vector2.add(a, b)` or `a.add(b)`); the call site picks per-context
per the style guide.

### Deliverables
- `Vector2.add/sub/scale/dot/length/lengthSq/distance/normalize/lerp/rotate/negate`
  + `init/zero/one`
- Same for Vector3 (with cross/project/reflect/transform)
- `Matrix` methods (multiply/invert/translate/rotate/scale/lookAt/perspective/ortho)
- `Color.lerp/fade/brightness/toHSV/fromHSV/init/rgb/hex` + `white/black/transparent`
- `Rectangle.contains/overlaps/intersection/topLeft/center/size/init`

Each method is a 1-3 line wrapper over existing free fns.  No new logic.

### LOC + tests
- types.zig: +400 LOC of methods
- types_test.zig (NEW): +250 LOC, ~50 host tests
- Final test count: ~290 (243 + 50)

## Sub-phase 12.2 — Resource type APIs

**Goal:** `Texture2D`, `Image`, `RenderTexture`, `Shader`, `Font`,
`Mesh`, `Model`, `Material` get `pub fn` declarations for
lifecycle (`deinit`), drawing (`draw/drawAt/drawPro`), and
manipulation.  The "method on a value" form (`tex.deinit()`,
`tex.draw(x, y, tint)`) reads naturally for these because there's a
clear receiver — but `Texture2D.deinit(tex)` works too.

### Deliverables
```zig
pub const Texture2D = extern struct {
    id: c_uint, width: c_int, height: c_int, mipmaps: c_int, format: c_int,

    pub fn deinit(t: Texture2D) void { ... }
    pub fn draw(t: Texture2D, x: c_int, y: c_int, tint: Color) void { ... }
    pub fn drawAt(t: Texture2D, pos: Vector2, tint: Color) void { ... }
    pub fn drawPro(t: Texture2D, src: Rectangle, dst: Rectangle,
                   origin: Vector2, rotation: f32, tint: Color) void { ... }
    pub fn isValid(t: Texture2D) bool { ... }
    pub fn update(t: Texture2D, pixels: []const u8) void { ... }
};
```

Same pattern for Image (resize/flipVertical/toTexture/...), Shader
(getLocation/setUniform/...), Font (drawText/measureText/...), etc.

### LOC + tests
- types.zig: +200 LOC
- ~30 new lifecycle tests

## Sub-phase 12.3 — Error unions

**Goal:** all `loadXxx` family fns return `Error!T`.  Sentinel returns
disappear entirely (no parallel C-shaped form).

### Deliverables
- `src/errors.zig` with `LoadError`, `ShaderError` enums
- Every loader updated: `pub fn loadTexture(allocator: Allocator,
  path: []const u8) LoadError!Texture2D`
- `png.LoadStatus.failed: LoadError` (tightening the existing `anyerror`)
- All sentinel-returning forms deleted

### LOC + tests
- errors.zig: +50 LOC
- Updated loaders: -100 LOC (removing fallback paths)
- Tests: +60 LOC

## Sub-phase 12.4 — PascalCase → camelCase rename

**Goal:** raylib's PascalCase fn names become Zig-idiomatic camelCase.
`DrawRectangle` → `drawRectangle`, `BeginMode3D` → `beginMode3D`, etc.

### Strategy
- Mechanical: every `pub fn FooName` and every call site renamed via
  scripted rename.  Bounded by the symbol set we already have.
- Standalone session because the diff is large and noisy — keeping it
  separate from semantic changes makes review easier.
- The PascalCase names are deleted, not aliased — examples in the same
  session get the new names.

### Risk
- Scripted rename can hit false positives (e.g., type names that
  happen to start with the same letters).  Use an explicit symbol
  list rather than regex-based renaming.

## Sub-phase 12.5 — Capability passing: `Io` and `Frame` redesign

**Background.** Zig 0.16 introduces `std.Io` (Andrew Kelley's
"Writergate"-and-beyond design), a capability handle that owns *all
nondeterministic operations* — async/await dispatch, futexes, time
(`now`, `sleep`), random bytes, filesystem, network.  Same pattern
as `Allocator` but for "things that touch the real world or take
wall-clock time."  See [LWN coverage](https://lwn.net/Articles/1046084/),
[kristoff.it walkthrough](https://kristoff.it/blog/zig-new-async-io/),
and [Kelley's text version](https://andrewkelley.me/post/zig-new-async-io-text-version.html).

The signature rule that emerges is sharp:
- **Pure fn** → no parameters except inputs/outputs
- **Allocates** → takes `Allocator`
- **Touches time, I/O, randomness, async** → takes `*Io`
- A function with neither is provably deterministic and trivially testable

zimr should adopt this fully.  Function signatures become an audit
trail: scanning `pub fn` decls tells you precisely which code paths
are nondeterministic without reading the bodies.

**Status of stdlib's wasm Io.**  Per the [LWN article](https://lwn.net/Articles/1046084/):
> "A third kind of Io, one that is compatible with WebAssembly, is
> planned (although... implementing it depends on some other new
> language features)."

Stdlib ships `Io.Threaded`, `Io.Evented` (fiber-based, io_uring/kqueue/
GCD backends), but no `Io.Wasm` or browser-targeted implementation
yet.  zimr fills the gap by defining its own `BrowserIo`.

### The clever idea: `Frame` is a *bounded `Io` view*

Most game-engine designs make `Frame` (per-tick state) and `Io`
(I/O capability) two separate things.  Update fns end up with awkward
two-arg signatures: `fn update(f: *Frame, io: *Io, state: *S)`.

zimr's design fuses them.  **`Frame` IS an `Io`** — same vtable, but
scoped to one tick.  The frame owns:
- A *time-pinned* `now()` — returns the frame's start timestamp,
  not real wall-clock.  Per-frame animations are deterministic
  regardless of how long the update fn takes.
- A *per-tick arena* allocator — auto-cleared at end-of-tick.
- A snapshot of input — immutable for the frame's duration.
- A reference back to the App-scoped `Io` for ops that outlive
  the frame (long async asset loads, audio streams).

```zig
fn update(f: *z.Frame, state: *AppState) !void {
    // Frame IS an Io — these all dispatch through the Io vtable
    // with frame-scoped semantics:
    const t = f.now();             // pinned to frame start
    state.particles.tick(f);       // pass *Frame because tick wants time + RNG
    f.clear(z.colors.slate_900);

    // For ops that outlive the frame, reach to App-scoped Io:
    if (f.input.isKeyPressed(.l)) {
        _ = try state.app.io.async(loadAsset, .{ state.app.gpa, "next.png" });
    }
}
```

The 99% case becomes "take `*Frame`, get everything you need."
Only long-lived async/concurrent ops reach to `*App` for the
unscoped Io.

This is the kind of API where the function signature *is* the
documentation.  `fn render(f: *Frame, ...)` says "I might draw,
read time, allocate temporarily."  `fn add(a: Vec2, b: Vec2) Vec2`
says "pure math."  No comment needed.

### `BrowserIo` — the wasm implementation

A vtable backed by browser primitives:

| `std.Io.VTable` slot | `BrowserIo` mapping |
|---|---|
| `now(clock)` | `performance.now()` (monotonic), `Date.now()` (wall) |
| `sleep(timeout)` | `setTimeout` + per-frame yield token |
| `random(buffer)` | `crypto.getRandomValues(buffer)` |
| `randomSecure(buffer)` | same — browser RNG is cryptographic |
| `async(fn, args)` | sync execution at first; future: Promise glue |
| `concurrent(...)` | `ConcurrentError.Unsupported` (no threads in browser) |
| `dirOpenDir/Stat/...` | Maps to fetch (read-only "filesystem") |
| `operate(op)` | Routes filesystem reads through fetch |
| `futexWait/Wake` | No-op (single-threaded) |

The fetch.zig two-phase pattern we already have is fundamentally
**Io.Evented-shaped**: non-blocking call returns a handle, poll
each frame for completion.  We just need to wire it through the
Io vtable instead of the bespoke `fetch.start` / `fetch.poll`
surface.

### Three Io flavors for testing

1. **`BrowserIo`** (production) — backed by browser APIs as above
2. **`MockIo`** (unit tests) — deterministic time advances explicitly
   by `mock.advance(seconds)`; deterministic RNG seed; in-memory
   "fetched" assets keyed by URL
3. **`LoggingIo`** (debugging) — wraps any Io and logs every call

This gives us proper unit tests for game logic without spinning
up a browser, and gives us deterministic-replay debugging (record
every Io call to a log, replay against MockIo to reproduce a bug).

### Function signature audit (mechanical pass)

Every `pub fn` in zimr gets categorized:
- `update_particles(particles: *[]Particle, dt: f32)` — pure-ish,
  takes data only
- `update_particles(particles: *[]Particle, f: *Frame)` — touches
  RNG (spawn jitter) and time, so takes `*Frame`
- `loadTextureFromMemory(gpa: Allocator, bytes: []u8) !Texture` —
  allocates, but no I/O or time → just allocator
- `fetchTexture(gpa: Allocator, io: *Io, url: []u8) !Future(Texture)` —
  async I/O → both allocator and io

Most existing zimr fns are pure or allocator-only; the I/O-touching
ones are concentrated in `core.zig`, `fetch.zig`, `png.zig`'s async
loaders, and `input.zig`.

### Deliverables

```zig
// src/io.zig (NEW, ~400 LOC)
pub const BrowserIo = struct {
    /// Returns a *std.Io that the rest of zimr code uses.
    pub fn io(self: *BrowserIo) std.Io { ... }

    fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp { ... }
    fn sleep(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void { ... }
    fn random(userdata: ?*anyopaque, buffer: []u8) void { ... }
    fn @"async"(...) ?*std.Io.AnyFuture { ... }  // sync impl initially
    // ... stubs that return Unsupported for concurrent/futex/etc.

    pub const vtable: std.Io.VTable = .{ ... };
};

pub const MockIo = struct { /* deterministic */ };
pub const LoggingIo = struct { /* wrapper */ };
```

```zig
// src/frame.zig (NEW or merged into zimr.zig, ~150 LOC)
pub const Frame = struct {
    /// Per-tick arena.
    arena: std.mem.Allocator,
    dt: f32,
    fps: f32,
    input: InputSnapshot,
    /// App-scoped Io — outlives this frame.  Reach for things like
    /// kicking off a long-running fetch.
    app_io: *std.Io,
    /// Frame-scoped Io view.  Time pinned to frame start.
    /// Same vtable as Io but with overrides for `now` and `sleep`.
    io_storage: std.Io,

    pub fn io(f: *Frame) *std.Io { return &f.io_storage; }

    /// Convenience accessors that go through the frame Io
    pub fn now(f: *Frame) std.Io.Timestamp { ... }
    pub fn clear(f: *Frame, color: Color) void { ... }
    pub fn drawRect(f: *Frame, rect: Rectangle, color: Color) void { ... }
};
```

### Strategy
1. Build `BrowserIo` first as a standalone module, get its smoke
   test passing
2. Add `Frame` with the pinned-time mini-Io
3. Update one example to use the new shape — verify size + smoke
4. Migrate `input.zig` and `fetch.zig` to consume `*Io` instead of
   bespoke entry points
5. Then rest of examples in 12.8

### LOC + tests
- io.zig: +400 LOC (BrowserIo + MockIo + LoggingIo)
- frame.zig + Frame redesign: +200 LOC
- Tests: +60 LOC (MockIo-driven deterministic update tests)

### Risks
- Comptime type-erasure for the user's update fn callback needs
  careful handling.  Spike on a single example first before the
  big migration.
- `io.async(fn, args)` semantics in wasm-no-threads is fuzzy —
  initial impl runs synchronously, future versions could use
  Promise glue or fiber-based stackful coroutines.  Document the
  initial sync semantics clearly so users don't assume parallelism.
- `MockIo` for unit tests is the highest-leverage piece — without
  it, "test game logic without a browser" stays aspirational.
  Build it early.

## Sub-phase 12.6 — App entry redesign

**Goal:** `z.init` takes explicit `.gpa` + `.io`.  Allocator-explicit
throughout.  Module-level state (`var state: AppState`) goes away in
favor of `init.gpa.create(AppState)` + the typed callback.

### The expected shape

```zig
const InitArgs = struct {
    gpa: std.mem.Allocator,
    io: *std.Io,
    window: WindowOptions,
};

pub fn init(args: InitArgs) !*App { ... }

pub fn main() !void {
    var browser_io: z.BrowserIo = .{};
    var io = browser_io.io();

    var app = try z.init(.{
        .gpa = std.heap.wasm_allocator,
        .io = &io,
        .window = .{ .title = "zimr v0.1" },
    });
    defer app.deinit();

    const state = try app.gpa.create(AppState);
    state.* = .{ .app = app, .tex = try z.loadTextureFromMemory(app.gpa, smiley_bytes) };

    try app.start(AppState, state, update);
}
```

### Resolved open question

The original sketch said `pub fn main(init: std.process.Init) !void`.
Verified during 12.5 research: `std.process.Init` does NOT exist in
stdlib.  Define our own `InitArgs` (or pull `gpa` and `io` from local
construction in `main`, as above).  Either way the user explicitly
constructs the gpa + io rather than receiving them from a magic
context.

### Strategy
- `z.init(.{ .gpa = ..., .io = ..., .window = ... })` rejects missing
  gpa with a clear comptime error
- `App.deinit()` releases per-app resources
- Examples construct their own `BrowserIo` + allocator at top of `main`

### LOC + tests
- App restructure: +150 LOC
- Tests: +40 LOC

## Sub-phase 12.7 — Port remaining env imports

**Goal:** the 4 remaining JS env imports become Zig fns.  `env: { ... }`
table in runtime.js shrinks to empty.

### What's there to port
- `getRandomValue(min, max)` — replace with `std.Random.DefaultPrng`
- `loadImageColors(image)` — pure CPU, ~30 LOC of pixel iteration
- `uploadMesh(mesh, dynamic)` — needs real rlgl_gpu vertex array setup;
  most of the underlying GL calls already exist
- `unloadShader(shader)` — small, calls rlgl_gpu shader cleanup

### LOC + tests
- ~250 LOC of new Zig
- Smoke + tests verify nothing regressed

## Sub-phase 12.8 — Examples migration + documentation

**Goal:** all 8 examples rewritten in the new API.  README leads with
the Zig-idiomatic shape.  Project is "1.0 ready".

### Strategy
- One example per session, in increasing complexity:
  basic → rtt → shader → keys → cube3d → png_demo → load_image_demo → life
- Each migration is verified via smoke before moving on
- README rewritten with the new "your first zimr program" tutorial

### Definition of done
- Every example uses `pub fn main(init: std.process.Init) !void`
- Every example uses method APIs and error unions
- README + STATUS reflect the new API as the only API
- Project is ready for external use

## Out-of-scope for Phase 12

Deferred to future work:

1. **Phase 9 raudio** — explicitly deferred per user.
2. **More image formats** (JPEG, QOI, BMP, TGA).
3. **GLTF / OBJ model loaders.**
4. **Gamepad polling.**
5. **Bilinear image resize** — current is naive nearest, ~30 LOC fix.
6. **Project layout reorg** — subdirs once file count grows further.

## Cumulative estimate

- Total Phase 12: ~12-15 sessions, ~3000 LOC new, ~1000 LOC removed
  (deleting C-ABI decorations + sentinel paths + parallel forms)
- Final test count target: ~340 host tests
- Final wasm sizes: 5-10% smaller than current (export table shrinkage)

## Open questions still pending

1. ~~**`std.process.Init`**~~ — RESOLVED in 12.5 research.  Doesn't
   exist in stdlib.  Defined our own `InitArgs` struct in 12.6.

2. **Per-frame update fn return type** — `void` or `!void`?  If
   `!void`, what happens on error — log and continue, or stop the loop?

3. ~~**`f.input` snapshot vs live view**~~ — settled on snapshot
   (immutability + cheap arena allocation per frame).

4. ~~**Method overload conventions**~~ — settled on the Style guide
   approach: methods and namespaced calls coexist; pick what reads
   best per call site.

5. **`io.async(fn, args)` semantics in browser context** — initial
   `BrowserIo` impl runs sync.  Future could use Promise glue or
   stackful coroutines via fiber.zig (if wasm becomes a `fiber.supported`
   target).  Document the limitation clearly so users don't assume
   parallelism.

6. **Whether to upstream `BrowserIo` to stdlib eventually** — Andrew
   Kelley's roadmap mentions wasm Io is planned but blocked on
   language features.  zimr's BrowserIo could be a useful proof-of-
   concept for stdlib once those features land.  Worth raising on
   ziggit once it's solid.

---

End of Phase 12 plan.

**Status (post-Session N+25):** sub-phases 12.0 through 12.4 ✅ done.
12.5 / 12.6 (Io capability passing + App entry redesign) remain
deferred per user instruction — see `ROADMAP.md` Section 4 (steps
39–48) for the resumed work plan.

**See also:**
- `ROADMAP.md` — the new master 100-step plan from "post-Phase-12"
  through to v1.0
- `DEPENDENCIES_PLAN.md` — pure-Zig replacements for raylib's C
  dependencies
- `PORTING_PLAN.md` — the original raylib-API porting plan with
  the section-9 audit that drove sequencing through Phase 12.4
