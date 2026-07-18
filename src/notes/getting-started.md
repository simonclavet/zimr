# Getting started with zimr

This guide walks you from "git clone" to "interactive 30-line app
running in your browser" in about 10 minutes.

## Prerequisites

- **Zig 0.16.0** or compatible.  zimr does NOT track Zig master.
  Get it from [ziglang.org/download](https://ziglang.org/download/)
  or your package manager.
- **Bun 1.0+** for the dev server, smoke tests, and TypeScript
  tooling.  `curl -fsSL https://bun.sh/install | bash` on macOS/Linux.
- **A modern browser** (Chrome 113+, Firefox 121+, Safari 17+).
  WebGL2 is required.

That's it.  No emscripten, no node_modules, no Python build scripts,
no system raylib.

## Clone, build, run

```sh
git clone <zimr repo>
cd zimr
zig build              # builds zig-out/web/
zig build serve        # opens a static-file server on :8000
```

Open `http://localhost:8000/basic.html` in your browser.  You should
see a pulsing magenta-and-cyan gradient with a textured triangle.
That's `examples/basic.zig`.

## Your first app

Create `examples/hello.zig`:

```zig
const std = @import("std");
const z = @import("zimr");

const State = struct {
    frame_count: u64 = 0,
};

pub export fn main() void {
    z.run(
        .{ .window = .{ .title = "Hello, zimr", .width = 640, .height = 360 } },
        State,
        initState,
        update,
    ) catch |err| {
        std.debug.print("zimr.run failed: {s}\n", .{@errorName(err)});
        return;
    };
}

fn initState(_: *z.Frame) !State {
    return .{};
}

fn update(f: *z.Frame, state: *State) void {
    state.frame_count += 1;
    f.clear(z.colors.slate_900);

    // A pulsing rectangle that follows the mouse.
    const t: f32 = @floatFromInt(state.frame_count);
    const size: c_int = @intFromFloat(40 + 20 * @sin(t * 0.05));
    const mouse = z.input.getMousePosition(f.input);
    z.shapes.drawRectangle(
        f.gl, f.shapes_texture,
        @as(c_int, @intFromFloat(mouse.x)) - @divFloor(size, 2),
        @as(c_int, @intFromFloat(mouse.y)) - @divFloor(size, 2),
        size, size,
        z.colors.amber_400,
    );

    z.text.draw(2, "Hello, zimr!", 12, 12, 24, z.colors.white);
}
```

Wire it into `build.zig`:

```diff
 const examples = [_][]const u8{
     "basic",
+    "hello",
     ...
 };
```

Then `zig build && zig build serve` and visit
`http://localhost:8000/hello.html`.  Move your mouse — there's a
pulsing amber square following it.

## Three things every zimr app does

1. **`pub export fn main()`** — the runtime calls this once at
   startup.  Runtime is wasi-reactor (no `_start`), so `main`
   must be `export`-ed explicitly.

2. **`z.run(cfg, State, initState, update)`** — sets up the
   canvas, GL context, RNG, allocates a `*State` on the
   long-lived gpa, calls `initState(f)` once, then starts
   the rAF loop dispatching `update(f, state)` per frame.
   All resources (textures, sounds, fonts) load through the
   same `*Frame` you see in `update`, so init and update
   share a single API surface.  Note: zimr does NOT ship a
   default font — apps that want to render text bake their
   own via `z.loadFontFromTtfBytes(gpa, &state.font_cache,
   @embedFile("..."), bake_size, &z.default_codepoints_ascii,
   1)` in `initState`.  Same principle as textures, audio,
   meshes: bring your own bytes.

3. **`fn update(f: *z.Frame, state: *State)`** — called once
   per browser `requestAnimationFrame` (typically 60 Hz).  `f`
   exposes the per-frame arena allocator (`f.scratch`), the
   long-lived gpa (`f.gpa`), the gl/drawing/audio substates
   (`f.gl`, `f.shapes_texture`, `f.skybox_cache`, etc.), the
   loader/clock/rng/log channels, the input snapshot, and the
   UI handle.  `f.clear(color)` is a convenience for the most
   common first call.

That's the whole programming model.  No `BeginDrawing()` /
`EndDrawing()` like raylib — the runtime brackets it for you.
You write what happens *inside* one frame.

`*z.App` is a dispatch implementation detail; user code never
touches it.  Hot reload (Phase F, future) re-uses the same
`initState(f, persisted)` signature with optional bytes for the
restore path — see `src/notes/hotreload-design.md`.

## What's in `z.*`?

- `z.core` — frame timer, FPS, `traceLog`, RNG.
- `z.input` — keyboard, mouse, touch, gamepad.
- `z.shapes` — 2D primitives (lines, rectangles, circles,
  polygons, splines).
- `z.text` — `draw`, `measureText`, `loadFont` (TTF support
  is Step 60, not yet shipped).
- `z.textures` — `Image` CPU ops, `Texture` GPU ops, PNG
  decoder, format conversion.
- `z.models` — 3D primitives, mesh upload, model rendering.
- `z.camera` — `Camera3D`, `Camera2D`, `beginMode3D`,
  `getScreenToWorldRay`, etc.
- `z.shaders` — load, set uniforms, blend / shader / scissor
  drawing modes.
- `z.colors` — Tailwind palette + raylib's classic colors.
- `z.audio` — Web Audio bindings (Phase 9 is the full engine).
- `z.types`, `z.enums`, `z.errors` — public type definitions.
- `z.raymath` — `Vector2/3/4`, `Matrix`, quaternion ops, eulers.

## Where to look next

- [`docs/architecture.md`](architecture.md) — the three layers,
  the import groups, the testing strategy.
- [`README.md`](../README.md) — full status of what's done and
  what's not.
- [`examples/`](../examples/) — 14 working programs covering
  every public API.  Read `basic.zig` first, then `cube3d.zig`,
  then whatever interests you.

## Common gotchas

- **`_ = error_value;`** — Zig 0.16 will fail if you don't either
  handle the error or `try` it.  Examples use `catch |err| { ... }`
  blocks; you can also `try` if your function returns an error
  union.
- **`[*c]f32` vs `?[*]f32`** — raylib's structs use C-pointer
  types (`Mesh.vertices`, etc).  Null-check with `== null`, NOT
  with `.?` (which only works on optionals).
- **Pointer-lock for FP camera** — calls into `disableCursor()`
  silently no-op until the user has clicked the canvas.  Browsers
  require a user gesture before pointer-lock can engage.
- **Audio init must follow a user gesture** — same reason.
  Calling `z.audio.init()` from `main` succeeds but the context
  stays "suspended" until the first click.

## Reporting bugs / contributing

zimr is in active development.  Things will move.  See
[`ROADMAP.md`](../ROADMAP.md) for the 100-step plan and
[`STATUS.md`](../STATUS.md) for the current snapshot.
