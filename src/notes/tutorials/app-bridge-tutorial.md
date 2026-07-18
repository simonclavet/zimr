# zimr's AppBridge architecture — and the `pub` bug

## TL;DR

The bug: every example declared `var zimr_app: z.AppBridge = .{};` without
`pub`. The framework reaches the user's `zimr_app` via
`@import("root").zimr_app` from inside its own code. Across module
boundaries, **only `pub` declarations are visible**. So `@hasDecl(root,
"zimr_app")` evaluated to `false` at comptime, the per-frame dispatch was
elided, and the canvas stayed blank with no runtime error.

The fix: bulk-add `pub` to all 112 examples + a compile-time guard in
`AppBridge.run` that emits a clear error if the user forgets.

The rest of this document explains *why* it worked this way and *why* the
bug stayed hidden for so long.

---

## 1. The architecture: who owns what

zimr is a Zig port of raylib + imgui, compiled to `wasm32-wasi` and
loaded into a browser canvas. The runtime split is:

```
┌──────────────────────────────────────────────────────────────┐
│ JS bridge (src/web/zimr.ts)                                  │
│  - instantiates the wasm                                     │
│  - provides WASI shim, DOM/canvas/GL/audio imports           │
│  - drives RAF, attaches event listeners                      │
└──────────────────┬───────────────────────────────────────────┘
                   │ calls exports: _initialize, main, zimr_frame
                   │ provides imports: dom, webgl, wasi, audio
┌──────────────────▼───────────────────────────────────────────┐
│ wasm instance                                                │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ Framework (src/zimr.zig + src/runtime_assembly.zig)    │  │
│  │  - AppBridge type, App lifecycle, frame dispatch       │  │
│  │  - input shims, viewport math, rlgl GPU layer          │  │
│  └─────────────────────┬──────────────────────────────────┘  │
│                        │ reaches user state via              │
│                        │ @import("root").zimr_app            │
│  ┌─────────────────────▼──────────────────────────────────┐  │
│  │ User example (examples/cube3d.zig)                     │  │
│  │  pub var zimr_app: z.AppBridge = .{};   ← *the bridge* │  │
│  │  pub fn main(init: std.process.Init) !void {           │  │
│  │      try zimr_app.run(init.gpa, .{...},                │  │
│  │          State, initState, update);                    │  │
│  │  }                                                     │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

Three pieces of state move across that bridge:

1. **AppBridge** — the user-owned struct that holds `app: ?*App`,
   `state: ?*anyopaque`, `update_fn: ?*const fn(...)`.  Lives in the
   user's example file as `pub var zimr_app`.

2. **App** — heap-allocated by the framework inside `AppBridge.run`.
   Owns the GL state, audio device, input state, window/viewport state.

3. **User State** — typed at compile time via `comptime State: type`.
   Heap-allocated by the framework, passed to user's `initState` and
   `update` callbacks.

The lifecycle:

```
JS                    Framework                  User
──────────────────────────────────────────────────────────────
instantiate wasm
  │
  ▼
_initialize()  ───►  Zig start.zig
                       │
                       │ (juicy main wrapper)
                       ▼
                     main(init)  ─────────────► your main()
                                                  │
                                                  ▼
                                            zimr_app.run(...)
                       ◄────────────────────────  │
                     AppBridge.run                 │
                       │                           │
                       │ creates App,              │
                       │ heap-allocs State         │
                       │ self.app = app  ◄── *KEY ASSIGNMENT*
                       │ calls user initState() ─► your initState()
                       │ self.update_fn = ...
                       │ app.start() ─────────► dom.start_loop()
                                              │
                                              ▼
                                      js_start_loop() ◄── back in JS
                                        │
                                        ▼
                                      attachInputHandlers()
                                      requestAnimationFrame(loopTick)
                                              │
                                              ▼ (next paint)
                                            loopTick()
                                              │
                                              ▼
                                      exports.zimr_frame()  ◄── back in wasm
                                              │
                                              ▼ ⚠ THIS IS WHERE
                                      @import("root").zimr_app
                                              │     ⚠ THE BUG LIVED
                                              ▼
                                       dispatchFrame()
                                              │
                                              ▼
                                          update()  ────────► your update()
```

The key thing about this flow: **the framework needs to find the user's
`AppBridge` instance from inside `zimr_frame`**, but `zimr_frame` is an
exported function with no parameters — JS calls it with nothing. The
framework needs some way to look up "where is the user's AppBridge?"

## 2. The framework's lookup mechanism

`zimr.zig` does this:

```zig
export fn zimr_frame() void {
    const root = @import("root");
    if (comptime @hasDecl(root, "zimr_app") and
        @TypeOf(root.zimr_app) == AppBridge)
    {
        root.zimr_app.dispatchFrame();
    }
    // else: silently no-op (intentional, for test runners that
    // don't have a zimr_app declared)
}
```

`@import("root")` returns the compilation's root module — the file
specified by `-Mroot=...` in the build command, which is the user's
example file (e.g. `examples/cube3d.zig`). The `comptime` block:

1. Checks if `root` has a declaration named `zimr_app`.
2. Checks if its type matches `AppBridge`.
3. If both pass: call `dispatchFrame()` on it.
4. If either fails: do nothing.

The "do nothing" branch is intentional — the test runner doesn't declare
`zimr_app`, but `zimr.zig` still needs to compile. Soft contract.

The same pattern lives in `src/runtime_assembly.zig` for the input shims:

```zig
inline fn currentRuntime() ?*Runtime {
    const root = @import("root");
    if (comptime !@hasDecl(root, "zimr_app")) {
        return null;
    }
    return &(root.zimr_app.app orelse return null).runtime;
}
```

Same shape: comptime check for `zimr_app`, return null if absent.

## 3. The bug

In Zig 0.16, when you access a top-level declaration of a type **from
another module via `@import`**, only `pub` declarations are visible.

User wrote:

```zig
var zimr_app: z.AppBridge = .{};   // ← no pub
```

From inside `zimr.zig` (a different module):

```zig
const root = @import("root");
@hasDecl(root, "zimr_app")  // returns FALSE
```

The comptime gate evaluates to false. The dispatch is elided. Every
frame, `zimr_frame` runs, finds no `zimr_app`, returns without doing
anything. The user's `update()` is never called.

**Critically**, from the user's *own* `main()`, the access works:

```zig
pub fn main(init: std.process.Init) !void {
    try zimr_app.run(init.gpa, ...);  // ← works, no @import involved
}
```

This is the user's *own scope*. `zimr_app` is a top-level decl in this
very file — `main()` doesn't need an `@import` to reach it, so the `pub`
modifier doesn't matter. The variable is directly in lexical scope.

`AppBridge.run()` then does `self.app = app` — assigning to a field
through a `*AppBridge` pointer. Pointer-based field access doesn't care
about `pub` either; it's a runtime memory write. The framework reaches
into the user's variable through the pointer the user just handed it.

So: `AppBridge.run()` runs to completion. `self.app = &app_struct` is
written. `dom.start_loop()` is called. RAF gets scheduled. JS fires
`loopTick`, which calls `exports.zimr_frame()`. zimr_frame runs and...
silently dispatches nothing because `@import("root").zimr_app` is
invisible.

## 4. Why this stayed hidden

Three reasons:

### 4a. The defensive shim change in turn 409c

Earlier in this debugging session, a separate bug surfaced: input shims
panicked if `zimr_app.app` was null. The fix (correctly) made the shims
silently drop events when the runtime isn't reachable. That fix used
the same `currentRuntime()` helper — which has the same `@hasDecl(root,
"zimr_app")` check.

So after 409c: input shims that arrived early (before `app.start`
returned) would silently no-op. **But also**, input shims that arrived
*ever* would silently no-op when `zimr_app` isn't pub. The defensive
fix accidentally masked the visibility bug too.

### 4b. The soft-contract gate in `zimr_frame`

Same `@hasDecl` check, same silent skip when the gate evaluates to
false. By design — test builds don't have `zimr_app`. The intent was
"compile cleanly when the user opts out by not declaring zimr_app." The
unintended consequence: "silently do nothing when the user *did*
declare it but forgot `pub`."

### 4c. Smoke tests don't drive frames

`zig build smoke-install` produces wasms and loads them in Bun, but
Bun's WASI runtime calls `_initialize` (which runs `main` → `init` →
`initState`) and stops. The smoke harness verifies exports exist and
init completes. It doesn't actually run frames. So the dispatch bug
never surfaced in CI — it only surfaces when you load a wasm in a
*browser* and `requestAnimationFrame` actually starts firing.

This is exactly why Simon's mobile browser test was the first to catch
it. The combination "real RAF + real GL + a deliverable that depends on
update() actually running" is the only setup that exercises this path.

## 5. The shape of the symptoms

The bug doesn't show up as a panic, a console error, or a crash. It
shows up as:

- **`main()` runs to completion** — visible via the dom log calls we added.
- **`initState()` runs to completion** — same.
- **`AppBridge.run` returns cleanly** — same.
- **`js_start_loop` is called** — visible JS-side.
- **`requestAnimationFrame` is scheduled** — visible JS-side.
- **`loopTick` fires** — visible JS-side.
- **`zimr_frame()` is called** — visible from a tracer added to it.
- **The comptime gate inside `zimr_frame` evaluates to false** — dispatch
  is elided, no error.
- **The user's `update()` is never called** — canvas stays at the HTML's
  CSS background color forever, because no `clearBackground` ever runs.

The only way to see what's happening is to instrument every step.

## 6. The fix

Two parts:

### 6a. Bulk patch the examples

```bash
sed -i 's|^var zimr_app: z\.AppBridge = \.{};|pub var zimr_app: z.AppBridge = .{};|g' examples/*.zig
```

112 files. All examples now declare `pub var zimr_app`.

### 6b. Compile-time guard in `AppBridge.run`

The soft contract is still useful — test code that doesn't declare
`zimr_app` should still compile against `zimr.zig`. But anyone who
actually calls `AppBridge.run()` is by definition a real example, not a
test runner. So inside `run()`, we can enforce the contract strictly:

```zig
pub fn run(self: *AppBridge, ...) !void {
    if (comptime !builtin.target.cpu.arch.isWasm()) {
        return error.HostBackendNotImplemented;
    }

    const root = @import("root");
    comptime {
        if (!@hasDecl(root, "zimr_app")) {
            @compileError(
                \\zimr: cannot reach `zimr_app` from the framework.
                \\
                \\Your example file must declare `zimr_app` as
                \\`pub`, like this:
                \\
                \\    pub var zimr_app: z.AppBridge = .{};
                \\
                \\The framework uses `@import("root").zimr_app`
                \\from `zimr_frame` to dispatch per-frame updates.
                \\Cross-module access to a top-level declaration
                \\requires `pub` — without it, `@hasDecl` returns
                \\false, the dispatch is silently elided, and your
                \\canvas stays blank with no runtime error.
            );
        }
        if (@TypeOf(root.zimr_app) != AppBridge) {
            @compileError(
                "zimr: `root.zimr_app` exists but has wrong type. " ++
                "Expected " ++ @typeName(AppBridge) ++ ", got " ++
                @typeName(@TypeOf(root.zimr_app)) ++
                ". Declare it as `pub var zimr_app: z.AppBridge = .{};`."
            );
        }
    }

    // ... rest of run ...
}
```

Now any future user who copies an old example, or forgets `pub`, gets:

```
src/zimr.zig:NN:NN: error: zimr: cannot reach `zimr_app` from the framework.

Your example file must declare `zimr_app` as
`pub`, like this:

    pub var zimr_app: z.AppBridge = .{};

The framework uses `@import("root").zimr_app`
from `zimr_frame` to dispatch per-frame updates.
Cross-module access to a top-level declaration
requires `pub` — without it, `@hasDecl` returns
false, the dispatch is silently elided, and your
canvas stays blank with no runtime error.
```

instead of a blank canvas + 30 minutes of bisection.

## 7. Generalizable lesson

Comptime soft-contracts (`if (comptime !@hasDecl(...)) return`) are
useful but dangerous: they convert misuse into silent no-op. When the
contract is "for tests only", that's a soft fallback. When the contract
gets exercised in production paths too, it becomes a footgun.

The fix isn't to remove the soft contract; it's to **move enforcement
to a checkpoint that's only hit on the real path**. `AppBridge.run` is
that checkpoint: tests don't call it; examples do.

Same lesson applies to defensive runtime checks. The "drop events when
runtime is null" fix from turn 409c is correct, but it also silences a
legitimate misconfiguration. The right combination is:

- **Strict at compile time** where you can prove the misuse is
  intentional misconfiguration (AppBridge.run).
- **Defensive at runtime** where the call path may legitimately fire
  before/after the system is alive (input shims during boot).

Both, not one or the other.
