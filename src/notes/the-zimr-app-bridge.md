# The zimr_app bridge: why your canvas was black

This is the tutorial Simon got after debugging the "no cube
rendered, no errors" mystery in turn 409.  It explains the
end-to-end lifecycle from `<script>` tag to `update()` firing,
the architectural pattern from the no-globals arc (turn 401),
the subtle Zig visibility rule that bit us, and the
compile-time guard that catches it now.

---

## 1. The cast of characters

There are four entities involved.  Knowing what each owns is
the prerequisite for understanding the bug.

### 1.1. The HTML page

A single self-contained `.html` file (built by
`scripts/build_standalone.py`) containing:
- A `<canvas>` element styled to fill the viewport.
- The compiled `zimr.js` bundle inlined as a `<script>`.
- The base64-encoded wasm bytes.
- A `<script type="module">` bootstrap that decodes the wasm
  and calls `zimrRun(blobUrl)`.

The HTML has its own CSS bg color (`#0f172a`, dark slate-blue).
**This is what you see before zimr renders anything** — and
what Simon saw in every screenshot of the broken build.  When
the canvas is transparent and zimr never draws into it, the
HTML bg shows through and looks for all the world like a
working "first clear to slate_950" call.

### 1.2. The JS bridge (`src/web/zimr.ts`)

A single TypeScript file that compiles via `bun build` into
`zimr.js`.  It provides:
- **WASI shim** (`makeWasi`): minimal implementations of
  `fd_write`, `fd_prestat_get`, `clock_time_get`, `proc_exit`,
  etc.  Any unimplemented WASI import returns `ERRNO_NOSYS`
  via a Proxy fallback.
- **DOM bridge** (`makeDom`): canvas dims, time, mouse/touch
  events, the request-animation-frame loop driver, image and
  font fetch helpers.
- **WebGL2 bindings** (`makeWebGL`): every GL call zimr uses
  is forwarded to the canvas's GL context.
- **Audio** (`createAudioImports`): Web Audio API wiring.
- **`zimrRun(src)`**: the public entry point.  Instantiates
  the wasm with all these imports, then dispatches
  `_initialize` → `zimr_init` → `main` in that order.

### 1.3. The framework (`src/zimr.zig` + siblings)

The "library" side of zimr.  Provides:
- `AppBridge`: a 4-field struct the USER declares one instance
  of.  Holds the `App` pointer, the user's state pointer, and
  the typed update function pointer.  Plays the role that a
  module-level `pub var app: ?*Runtime` would play in a
  globals-using design.
- `AppBridge.run(...)`: the setup entry the user calls from
  their `main`.  Builds the `App`, runs the user's `initState`,
  calls `dom.start_loop()` to ask JS to start the RAF loop,
  and returns.
- `zimr_frame()`: an `export fn` that JS calls every RAF tick.
  Reaches the user's AppBridge via `@import("root").zimr_app`
  and dispatches one frame of `update()`.
- `currentRuntime()` (in `runtime_assembly.zig`): the input-
  side complement.  Same `@import("root").zimr_app` lookup so
  mouse/touch/keyboard event shims can find the runtime.

### 1.4. The user's example file

A single `.zig` file that becomes the wasm's ROOT MODULE.
Three required pieces:

```zig
const std = @import("std");
const z = @import("zimr");

const State = struct { /* user fields */ };

// REQUIRED: the framework reaches this via @import("root").
// Must be `pub` — see §4 for why.
pub var zimr_app: z.AppBridge = .{};

pub fn main(init: std.process.Init) !void {
    try zimr_app.run(init.gpa, .{ .window = .{ ... } },
        State, initState, update);
}

fn initState(gpa: std.mem.Allocator, _: *z.Frame, s: *State) !void { ... }
fn update(f: *z.Frame, s: *State) void { ... }
```

That's the entire convention.  No `pub` on init/update — the
framework takes them as comptime args.  `pub` on `zimr_app` is
the load-bearing detail that this whole tutorial is about.

---

## 2. The lifecycle from page load to your first frame

In wall-clock order, from "browser parses HTML" to "your
`update` runs":

```
1. Browser parses <html>, layouts the <canvas>, applies CSS bg.
2. <script type=module> runs.  Calls zimrRun(blobUrl).
3. zimrRun:
   3a. Creates the WebGL2 context.
   3b. Builds the imports table (WASI + DOM + WebGL + audio).
   3c. fetch(blobUrl) → instantiate wasm with imports.
   3d. Attaches ResizeObserver + dragover/drop listeners
       (NOTE: no input listeners yet — those wait for the
       wasm to call dom.start_loop).
   3e. Calls exports._initialize() — the WASI reactor hook.
4. _initialize (Zig's start.zig wrapper):
   4a. Runs WASI initialization (enumerates preopens —
       see the turn 409b changelog for that adventure).
   4b. Constructs std.process.Init and calls user's main(init).
5. User's main:
   5a. Calls zimr_app.run(init.gpa, cfg, State, initState, update).
6. AppBridge.run:
   6a. Comptime guards: verify root has `pub var zimr_app`
       with the right type.  Fails to compile if not.  (§5)
   6b. App.init: creates GL state, allocates the runtime
       struct, sets viewport, seeds the input arena.
   6c. self.app = app — NOW the AppBridge has a non-null
       Runtime to dispatch through.
   6d. Allocates State, calls user's initState() with a
       "first frame" so they can load fonts, set up data.
   6e. Stores the typed update_fn dispatcher thunk.
   6f. Calls app.start → dom.start_loop().
7. dom.start_loop (JS):
   7a. Calls attachInputHandlers (mouse/touch/keyboard).
   7b. Schedules first RAF: requestAnimationFrame(loopTick).
   7c. Returns.
8. AppBridge.run returns.  main returns.  _initialize returns.
9. RAF fires (next vsync).
10. loopTick runs:
    10a. state.exports.zimr_frame() — the wasm export.
11. zimr_frame (in zimr.zig):
    11a. const root = @import("root").
    11b. if (comptime @hasDecl(root, "zimr_app") and
            @TypeOf(root.zimr_app) == AppBridge) {
            root.zimr_app.dispatchFrame();
        }
    11c. dispatchFrame: extract app + update_fn, call
        dispatchFrameOn(app, state, update).
12. dispatchFrameOn:
    12a. Refresh canvas size (detects resize, sets viewport).
    12b. Build the per-frame Frame struct (input snapshot,
         GL handle, time, window).
    12c. update(&frame, user_state) — YOUR FIRST FRAME!
13. loopTick reschedules RAF.  Loop forever.
```

Every step has to work, in order, for you to see one frame.
Each step has its own failure mode and its own diagnostic
strategy.  The bug we hit was at step 11b.

---

## 3. The no-globals architecture (turn 401)

Pre-turn-401 zimr had two framework-owned module-level vars:

```zig
// src/zimr.zig
var bridge: Bridge = .{};        // ← global

// src/runtime_assembly.zig
pub var app: ?*Runtime = null;   // ← global
```

The framework's `zimr_frame` would reach `bridge.update_fn`;
the input shims would reach `app.?.input`.  Both worked.

The problem with this design is in framework code, not user
code: it makes multi-instance scenarios impossible (you can
only have one zimr app per wasm), it makes tests harder
(globals leak between test runs), and it's the wrong pattern
for "library" code that wants to support multiple consumers.

Turn 401 deleted both globals.  The replacement is the
**user-owned global**: the framework defines an `AppBridge`
type, but the user declares the actual VARIABLE in THEIR file:

```zig
// In examples/your_app.zig — user's file
pub var zimr_app: z.AppBridge = .{};
```

The framework reaches it via `@import("root").zimr_app`.  This
inverts ownership: the user controls the lifetime, the
framework just supplies the type.

This is the SAME pattern Zig stdlib uses for `pub fn main`,
`pub const std_options`, `pub const panic`, etc.  Stdlib
defines the contract; the user provides the implementation in
their root file; stdlib reaches it via `@import("root")`.

---

## 4. The visibility rule that bit us

In Zig, when you `@import` another file, you get a struct type
representing that file's top-level namespace.  Accessing
declarations on that struct from OUTSIDE the file follows
visibility rules:

| Decl in file A | Visible from file B via `@import` |
|---|---|
| `pub const X = ...;` | YES |
| `pub var X = ...;` | YES |
| `const X = ...;` | NO |
| `var X = ...;` | NO |

The compiler-level check is `@hasDecl(SomeImported, "X")` —
which returns **true only if X is pub**.

Here's the empirical proof from `@compileLog`:

```
=== NON-PUB var zimr_app ===
@compileLog("@hasDecl=", @hasDecl(root, "zimr_app"))
→ @as(bool, false)

=== PUB var zimr_app ===
@compileLog("@hasDecl=", @hasDecl(root, "zimr_app"))
→ @as(bool, true)
```

Same source, only `pub` changed.  Same result for any
cross-module decl access — direct field access (`root.zimr_app`)
also fails to compile when zimr_app isn't pub.

**But the user's own code STILL compiles**, because:
- `zimr_app.run(...)` from inside the user's file isn't an
  `@import` boundary — it's a direct variable reference.
- The user's `var zimr_app` (no `pub`) is valid Zig — it just
  isn't visible elsewhere.

So the user's example compiles, runs, gets past every check,
and the framework's `@hasDecl(root, "zimr_app")` quietly
returns false.

---

## 5. How that combination produces a silent black screen

The framework had `zimr_frame` shaped like this:

```zig
export fn zimr_frame() void {
    const root = @import("root");
    if (comptime @hasDecl(root, "zimr_app")
        and @TypeOf(root.zimr_app) == AppBridge) {
        root.zimr_app.dispatchFrame();
    }
}
```

The `if (comptime …)` evaluates BOTH conditions at compile
time.  If the result is false, the whole `if` branch is
elided — the function compiles to an empty body, and at
runtime calling `zimr_frame` is a no-op that returns
immediately.

The check was deliberately permissive for a reason: when zimr
is compiled as part of a HOST test binary that DOESN'T declare
zimr_app (the test runner, library-only typecheck objects),
the framework's `zimr_frame` export still needs to LINK — it
just doesn't need to do anything.  So the comptime gate makes
the body empty in those cases.

The bug is that this gate ALSO fires for a real wasm build
whose user just forgot `pub`.  In both cases, from the
framework's perspective, "root has no zimr_app".  The two
cases look identical and both produce an empty `zimr_frame`.

End result:

- JS's `_initialize → main → AppBridge.run` runs cleanly.
- RAF schedules.  Every tick, JS calls `zimr_frame`.
- `zimr_frame` returns immediately (empty body).
- `update()` never fires.
- `clearBackground()` never called.
- Canvas stays transparent.
- HTML's CSS bg (`#0f172a`) shows through.
- It looks like "first clear worked, nothing else did."

Same story for the input shims in `runtime_assembly.zig`:
`currentRuntime` returns null because `@hasDecl(root, "zimr_app")`
is false; mouse/touch/keyboard events get silently dropped.
A user who happened to test interactivity first would have
hit this same wall.

---

## 6. The bisection that found it

The diagnostic strategy that surfaced the bug (in turn 409
across screenshots):

1. **Screenshot 1: just dark blue**.  Confused us — we assumed
   `clearBackground(slate_950)` had run.  Wrong.
2. **Add `dom.log` checkpoints across the wasm startup chain**
   in `examples/cube3d.zig`:
   - main() entered
   - initState() entered → about to load font → font loaded →
     done
   - main() — zimr_app.run returned cleanly
   - update() — FIRST FRAME
3. **Screenshot 2**: every checkpoint EXCEPT the last appeared.
   So `AppBridge.run` returned successfully but `update()`
   never fired.  Narrowed the bug to the
   `start_loop → RAF → loopTick → zimr_frame → dispatchFrame`
   chain.
4. **Add JS-side logs in `js_start_loop` and `loopTick`** in
   `src/web/zimr.ts`, plus a log inside `zimr_frame` itself
   with an `else` branch that explicitly says "comptime gate
   FALSE":
   - `[js] js_start_loop entered, typeof zimr_frame=function`
   - `[js] js_start_loop: RAF scheduled`
   - `[js] loopTick #1`
   - `[zimr_frame] tick #1`
   - `[zimr_frame] comptime gate FALSE — no zimr_app or wrong type`
5. **Screenshot 3** showed exactly that final line.  Gate was
   false.  Within 30 seconds of seeing it: "ah, it's pub."

The pattern worth internalizing: **add a checkpoint at every
boundary, in BOTH directions of every cross-boundary call**.
Wasm logs (`dom.log`) on the Zig side.  `console.log` on the
JS side.  The interesting bugs are at the boundaries; logging
both sides of every boundary surfaces them in one pass.

---

## 7. The fixes

Two complementary fixes landed:

### 7.1. Bulk-add `pub` to every example

All 112 example files migrated:

```zig
- var zimr_app: z.AppBridge = .{};
+ pub var zimr_app: z.AppBridge = .{};
```

One sed.

### 7.2. Compile-time guard in AppBridge.run

A new comptime check at the TOP of `AppBridge.run` catches the
missing-`pub` case at compile time.  The strategy:

```zig
const root = @import("root");
comptime {
    if (!@hasDecl(root, "zimr_app")) {
        @compileError(
            \\zimr: root has no `zimr_app` declaration.
            \\Your example file must declare it at the top:
            \\    pub var zimr_app: z.AppBridge = .{};
        );
    }
}
// Force address resolution — fails to compile if zimr_app
// exists but has the wrong type.
const canonical: *AppBridge = &root.zimr_app;
if (self != canonical) {
    dom.panic("AppBridge.run called on a non-canonical instance...");
}
```

Three guards in one block:

| Check | Catches | When |
|---|---|---|
| `@hasDecl` in comptime block | non-pub declaration, or no declaration at all | Compile time, with a clear `@compileError` |
| Address resolution as `*AppBridge` | wrong type (e.g. user declared `var zimr_app: SomeOtherType`) | Compile time, type-mismatch error |
| `self != canonical` runtime check | user has two AppBridge instances and called .run on the wrong one | Runtime, via `dom.panic` |

The guard sits in `AppBridge.run` because that's the function
the user explicitly calls.  Once they call it, they MUST have
`zimr_app` declared (the call wouldn't compile otherwise) and
the framework requires that decl to be reachable via
`@import("root")`.  Failing fast there gives the user a
diagnostic right at the line they wrote.

Verification:

```bash
$ zig build install -Dfocus=missing_pub_check
src/zimr.zig:2107:17: error: zimr: root has no `zimr_app` declaration.
                @compileError(
error: 1 compilation errors
```

That's a real test run with a fixture that has `var zimr_app`
instead of `pub var zimr_app`.  Compilation fails with a
clear error pointing at the right concept.

The previously-permissive comptime gate in `zimr_frame` itself
is **kept as-is** — it still needs to handle "library typecheck
objects with no zimr_app" so the framework links cleanly into
test binaries.  But `AppBridge.run` is the user-facing entry,
and IT is where the strict guard belongs.

---

## 8. Takeaways

Three lessons worth carrying forward:

1. **`pub` visibility crosses module boundaries.**  When a
   framework reaches user code via `@import("root").X`, X
   must be `pub`.  This is true for `pub fn main`, for
   `pub const std_options`, for any framework-discovered
   declaration.  zimr's `pub var zimr_app` is the same
   pattern; the requirement isn't novel, just less-documented.

2. **Defensive null checks can mask configuration bugs.**
   Turn 409c's "drop input events when runtime is null" fix
   was correct in isolation — but combined with the
   permissive comptime gate in `zimr_frame`, it removed the
   only signal that the bridge wasn't wired up.  Pre-409c,
   a touch event would have panicked with "Runtime not
   initialized" — a misleading message, but a SIGNAL.  Post-
   409c, the screen just stayed black.  Lesson: when adding
   a "be lenient" branch, audit the other lenient branches
   nearby — together they can completely silence a class of
   bug.

3. **Bisect with logs at boundaries.**  When a multi-component
   pipeline silently produces no output, instrument every
   call boundary in both directions.  Each log line is one
   bit of bisection information.  Five well-placed logs
   localize the bug to one of six segments; five more pin it
   to one line.  Total cost: 10 minutes.  Cost of speculating
   without logs: hours.

---

## 9. The compile-time guard now in place

If you ever see this error:

```
src/zimr.zig:2107:17: error: zimr: root has no `zimr_app` declaration.

Your example file must declare it at the top:
    pub var zimr_app: z.AppBridge = .{};
```

The fix is exactly what the error says: add `pub` to your
`zimr_app` declaration (or add the declaration if you forgot
it entirely).  The framework now refuses to compile your
example until that's right.  You will never again ship a
binary that silently no-ops every frame for this reason.
