# Architecture

How zimr is put together.  This is the "I want to contribute or fork
zimr" document; for "I want to use zimr to make something" see
[`getting-started.md`](getting-started.md).

## The three-layer cake

zimr is a Zig codebase that compiles to **WebAssembly (wasm32-wasi)**
and runs in a browser via a thin JavaScript runtime.  Three layers
talk to each other through the wasm import interface:

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 3 — Browser host                                     │
│  ─────────────────────                                      │
│  src/web/runtime.js  loads & instantiates the wasm,         │
│  src/web/wasi.js     fakes the WASI fds the wasm imports,   │
│  src/web/dom.js      DOM/canvas/time/fetch bridge,          │
│  src/web/gl.js       WebGL2 wrapper,                        │
│  src/web/audio.js    Web Audio API bridge,                  │
│  src/web/host.html   single-page wrapper used by `serve`.   │
└─────────────────────────────────────────────────────────────┘
            ↓  wasm imports                ↑  wasm exports
┌─────────────────────────────────────────────────────────────┐
│  Layer 2 — Zig wasm32-wasi binary                           │
│  ─────────────────────────────────                          │
│  src/zimr.zig        public surface (re-exports modules),   │
│  src/{core, input, shapes, textures, text, models,          │
│       camera, shaders, raymath, rlgl, rlgl_gpu, png,        │
│       truetype, errors, colors, types, enums}.zig           │
│  src/_vendor/{truetype, zg}/   pure-Zig third-party deps.   │
│  src/{allocator, libc, wasm_fwd}.zig  glue layer.           │
└─────────────────────────────────────────────────────────────┘
            ↓  imports std.Io / std.heap.wasm_allocator
┌─────────────────────────────────────────────────────────────┐
│  Layer 1 — Zig stdlib                                       │
│  ──────────────────────                                     │
│  std.heap.wasm_allocator  backs zimr's libc.zig malloc shim │
│  std.compress.flate       PNG IDAT inflate                  │
│  std.fmt                  formatting in core.zig            │
│  std.mem                  pointer + slice utilities         │
└─────────────────────────────────────────────────────────────┘
```

Layer 3 is JavaScript, Layer 2 is Zig→wasm, Layer 1 is the Zig
standard library (already inside the wasm binary; mentioned
separately because it's a *boundary*).

## Three import groups

When `runtime.js` calls `WebAssembly.instantiate(bytes, imports)`,
it passes an object with **three named groups**:

| Group | Source | Purpose |
|---|---|---|
| `wasi_snapshot_preview1` | `src/web/wasi.js` | Minimal WASI fd implementation — `fd_write` (logging), `fd_close`, `fd_seek`, `fd_fdstat_get`, `proc_exit`, etc.  Only what `std.debug.print` and friends actually call. |
| `dom` | `src/web/dom.js` | Canvas, time, frame loop, fetch, pointer-lock.  About 20 functions.  See `src/web/dom.zig` for the Zig-side declarations. |
| `webgl` | `src/web/gl.js` | WebGL2 wrapped to look like raw GL ES 2.0.  About 80 functions.  See `src/web/gl.zig`. |
| `audio` | `src/web/audio.js` | Web Audio API binding — proof-of-shape for now (Phase 9 expands). |

Adding a fourth import group is mechanical:

1. Create `src/web/<name>.zig` with `extern "<name>" fn js_xxx(...)`.
2. Create `src/web/<name>.js` exporting an init function that
   returns the import object.
3. Add to the `imports` object in `src/web/runtime.js`.
4. Add stubs to `tests/smoke.ts` so smoke can still instantiate.

## The `wasm_fwd.zig` forwarder pattern

zimr modules generally look like:
- Pure-CPU work (math, format dispatch, layout) → directly in the
  module (e.g., `imageResize` in `textures.zig`).
- GPU-touching calls (`glUniform4f`, `glDrawElements`, etc.) → go
  through `wasm_fwd.zig`, which is the **only** module that
  imports `web/gl.zig`.

Why?  Because `web/gl.zig` declares `extern "webgl" fn …` — those
are wasm imports that **don't exist** when the build target is the
host (Linux x86_64) for unit tests.  Routing every GPU call through
`wasm_fwd.zig` lets us comptime-gate the body:

```zig
pub fn rlSetUniform(loc: c_int, value: ?*const anyopaque, ...) void {
    if (comptime is_wasm) @import("rlgl.zig").rlSetUniform(...);
    // No-op on host target — host tests can call into modules that
    // call this without a link error.
}
```

This is what lets us run **389 host unit tests** on pure-CPU code
without a browser, even when the function under test transitively
calls into `gl.uniform4f`.

## Three memory tiers (target end-state)

The current state is **two-tier-mostly-one-tier**.  Phase 12.5/12.6
(roadmap §4-§5) lands the third tier and explicit allocator
threading.

| Tier | Owner | Lifetime | What lives here |
|---|---|---|---|
| 1: GPA | Application | Process-long | `Texture2D` GPU handles, `Font` glyph atlases, `Shader` programs.  Survives across frames. |
| 2: Frame arena | `App` | One frame | Per-frame allocations: `std.fmt.allocPrint` for HUD strings, scratch buffers for blur, decoded UTF-8 buffers in `imageDrawText`. |
| 3: Io capability | (planned) | Bound to a request | Async fetch responses, one-shot file loads.  Threaded explicitly through call sites that perform IO. |

Today, GPA is `std.heap.wasm_allocator` and Frame is also derived
from it.  The Step 56-63 work tightens this up.

## Build pipeline

`build.zig` defines:

- One **wasm32-wasi target**, optimized `ReleaseSmall` by default
  (size matters more than micro-perf for browsers).
- A **single `zimr` module** at `src/zimr.zig` that every example
  imports.
- One **executable per example file** in `examples/` — wasi-reactor
  style (`exe.entry = .disabled`, `exe.rdynamic = true`).
- A **host test target** that runs `src/*_test.zig` + the vendored
  test files on the native target — no wasm involved.
- A **smoke-test target** that runs `tests/smoke.ts` via `bun`,
  loading every `.wasm` in `zig-out/web/` and running 3 frames
  headless against a fake GL.

`zig build serve` runs `tests/server.ts` which is a static-file
Bun server with the right MIME types and CORS for `.wasm` files.

## Testing strategy

- **Host unit tests** (`zig build test`) — pure-CPU code.  389 tests
  today.  Anything that touches GL or browser globals is gated
  behind `comptime is_wasm` and stubbed on host.
- **Smoke tests** (`zig build smoke-test`) — every example wasm
  loads, runs 3 frames, and emits at least 100 GL calls
  (`MIN_GL_CALLS = 100`).  Catches "silently no-op" regressions.
- **Eyeball tests** (`zig build serve` + browser) — for visual
  correctness.  No automated visual regression yet (Step 32 plans
  it).

## Standing rules

These show up in `ZIGGIFY_NOTES.md` repeatedly because they're
non-negotiable:

1. **No C compilation, ever.**  Vendored deps must be pure-Zig.
   stb_truetype port (`andrewrk/TrueType`) good; raylib's
   `external/stb_truetype.h` bad.
2. **Wasm32-wasi only** for v0.1.  Native-target work is post-1.0.
3. **No env imports.**  As of Phase 12 (Session N+13) the import
   list is exactly `wasi_snapshot_preview1`, `dom`, `webgl`,
   `audio`.  If you find yourself wanting `env: { ... }` you're
   missing a forwarder in `wasm_fwd.zig`.
4. **Host tests cover everything possible.**  When a function uses
   `libc.malloc` (which returns null on host), at minimum keep a
   defensive-paths test that exercises the null-data branch.
5. **Smoke after every example** — add to `build.zig`'s `examples`
   list before declaring done.
