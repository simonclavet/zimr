# state-explicit Phase 0 — inventory

Every file-scope `var` in zimr that survives across function calls
(i.e. holds module state, not just a fn-body local).  This is the
budget for the rest of the refactor.

Methodology: file-scope `var` declarations only — depth 0 or one level
into a `pub const X = struct {}` namespace.  Test-body and fn-body
locals filtered out.

## Surprising findings

- **`web.zig` has zero module state.**  All "state" is JS-side; the
  wasm side is pure extern fns.  No work needed in Phase 3d for
  web.
- **`ui.zig` has zero module state.**  `UiContext` has been threaded
  through from day one.  This is the model the rest of the codebase
  is moving toward.
- **`codecs.zig` has zero module state.**  png/truetype/rectpack are
  per-call decoders.  No work needed.
- **`rlgl.zig` has six module vars, not one.**  `RLGL: State` is the
  big one, but `defaultBatch`, `draws`, `drawCounter`,
  `current_framebuffer`, `g_point_size` are also file-scope and
  should be folded into the consolidated `GlState`.

## Inventory

### `src/rlgl.zig` — top-level (the boss)

| Line | Var | Type | Notes |
|---:|---|---|---|
| 285 | `RLGL` | `State` | Monolithic — matrix stacks, mode, transformRequired, batch refs, etc. |
| 290 | `defaultBatch` | `VertexBuffer` | Active vertex/color/texcoord buffers + VAO/VBO ids |
| 291 | `draws` | `[256]DrawCall` | Per-batch draw call records |
| 299 | `drawCounter` | `usize` | Index of next free draw slot in `draws` |
| 2141 | `current_framebuffer` | `c_uint` | Bound FBO id (avoids GL round-trip) |
| 2594 | `g_point_size` | `f32` | rlGetPointSize mirror (WebGL2 has no glPointSize) |

Phase 1d consolidation: fold all six into a single `pub const GlState`
type.  Internal refs change from `RLGL.X` / bare `defaultBatch` /
bare `drawCounter` to `gl.X` / `gl.batch` / `gl.draw_counter`.

Caller surface: drawing.shapes, drawing.textures, drawing.text,
drawing.models, drawing.shaders — every primitive draw and every
shader bind reaches in.  This is the largest migration step
(Phase 3e).

### `src/runtime.zig` — `core` namespace

| Line | Var | Type | Notes |
|---:|---|---|---|
| 143 | `STATE` | `CoreState` | Time + window + FPS averaging + drop events |
| 150 | `nowFn` | `*const fn () f64` | Test injection point for fake clock |
| 299 | `defaultSink` | `?*const fn (c_int, []const u8) void` | traceLog default sink |
| 753 | `rng_state` | `u32` | Random seed for `getRandomValue` (raylib parity) |

Phase 1b split: `CoreState` is doing too much.  Break into `TimeState`
(base/current/previous/frame/target/frameCounter), `WindowState` (size,
focus, exit_request, drop_events), `FpsState` (rolling average buffer +
last-sample timestamp).  `nowFn` and `defaultSink` move to the new
top-level `Runtime` (they're cross-cutting injection points, not core
state).  `rng_state` becomes part of an `RngState` value (separate
from the existing `effects.rng.Seeded` which is for game/sim use).

### `src/runtime.zig` — `input` namespace

| Line | Var | Type | Notes |
|---:|---|---|---|
| 1457 | `STATE` | `InputState` | Keyboard/mouse/gamepad arrays + queues |

Phase 1a — already typed cleanly, just hoist out as the canonical
`InputState`.  Smallest migration; sets the pattern for the others.

### `src/runtime.zig` — `gestures` namespace

| Line | Var | Type | Notes |
|---:|---|---|---|
| 2745 | `STATE` | `GesturesData` | `pub var` — gesture detector state |
| 2906 | `prev_count` | `c_int` | Previous-frame finger count |
| 2907 | `prev_p0` | `Vec2` | Previous-frame finger 0 pos |
| 2908 | `prev_p1` | `Vec2` | Previous-frame finger 1 pos |

Phase 3c — small, isolated.  The three `prev_*` vars are an internal
detail of the multi-finger update; fold into `GesturesState`.

### `src/runtime.zig` — `camera` namespace

| Line | Var | Type | Notes |
|---:|---|---|---|
| 3113 | `debug_3d_log_count` | `u32` | Throttle counter for 3D-debug spam |

Phase 3c — trivial.  Either move to `CameraState` (overkill for one
counter) or accept it as a debug-only throttle and leave (it's not
*game* state, it's *log-rate-limit* state).  Recommendation: bundle
into a future `DebugState` if/when more such counters arrive; until
then, it's borderline.

### `src/drawing.zig` — `shapes` namespace

| Line | Var | Type | Notes |
|---:|---|---|---|
| 75 | `tex_shapes` | `Texture2D` | 1×1 white pixel for solid-color primitives |
| 82 | `tex_shapes_rec` | `Rectangle` | Source rect within the shapes texture |

Phase 3c — `ShapesTextureState`.  Small, self-contained.

### `src/drawing.zig` — `text` namespace

| Line | Var | Type | Notes |
|---:|---|---|---|
| 7890 | `line_spacing` | `i32` | Default vertical line spacing for `drawText` |
| 9424 | `loaded` | `bool` | First-call latch for `getDefaultFont` |
| 9425 | `default_font` | `Font` | Built default font (atlas + glyph table) |
| 9434 | `glyphs_buf` | `[GLYPH_COUNT]GlyphInfo` | Backing storage for default font's glyphs slice |
| 9435 | `recs_buf` | `[GLYPH_COUNT]Rectangle` | Backing storage for atlas rects |
| 9447 | `default_glyph_pixels` | `[N]u8` | Decoded glyph alpha pixels |
| 9453 | `default_font_pixels` | `[N]u8` | Atlas RGBA pixels |

Phase 3c — bundle 9424-9453 as `FontDefaults` (one-shot lazy init);
`line_spacing` becomes a separate `TextState` field (it's a runtime
setting, not init-once data).

### `src/drawing.zig` — `models` namespace

| Line | Var | Type | Notes |
|---:|---|---|---|
| 14615 | `skybox_cache` | `SkyboxCache` | Cached skybox shader + cube mesh |

Phase 3c — `SkyboxCache` is already a typed struct, just hoist it.

### `src/sound.zig` — multiple namespaces

| Line | Namespace | Var | Type | Notes |
|---:|---|---|---|---|
| 62 | `audio_device` | `state` | `State` | Audio device init state |
| 322 | `music` | `music_table` | `MusicTable` | Loaded music tracks |
| 1004 | `streams` | `stream_table` | `StreamTable` | Active audio streams |
| 1504 | `sounds` | `sound_table` | `SoundTable` | Loaded sound effects |
| 2462 | `waves` | `alloc_table` | `AllocTable` | Wave allocation tracking |

Phase 3d — bundle as `AudioState` aggregating five sub-tables.

## Effect handles (already explicit-state, no work)

These already use the vtable + userdata pattern.  No migration needed
beyond plumbing them through `Runtime`:

- `effects.clock` — `Browser` (singleton accessing real clock) +
  `Mock` (test fake)
- `effects.logger` — `Browser` (forwards to traceLog) + `Capture`
  (test fake) + `Prefixed` (decorator)
- `effects.rng` — `Browser` (system PRNG) + `Seeded` (deterministic)
- `effects.loader` — `Browser` (real fetch) + `Mock` (test fake) +
  `Scoped` (path-prefix decorator)

These get added to `Runtime` as ready-made fields.  No code change
beyond construction-site updates.

## Test-only globals (separate cleanup)

Some accessors and test-only vars survive in the impl files alongside
the real state.  These go away in Phase 3 when each subsystem migrates:

`rlgl.zig`:
- `_testReset`, `_testGetModelview`, `_testGetProjection`,
  `_testGetTransform`, `_testGetStackCounter`, `_testGetTransformRequired`,
  `_testGetVertexCount`, `_testGetDepth`, `_testGetDrawCallCount`,
  `_testGetDrawCall`, `_testReadVertex`, `_testReadColor` — replaced
  by direct field access on a stack-owned `GlState`.

`runtime.zig core`:
- `_testReset`, `_testSetNowFn` — go away when CoreState is split and
  `nowFn` becomes a Runtime field.
- Test-only `fake_now_ms` (line 889) — currently a global var inside
  the `core` namespace's test block.  Becomes a stack local once
  `nowFn` injection is parameterized.

`runtime.zig input`:
- `_testReset`, `_testKeyDown`, `_testKeyUp`, `_testMousePos`,
  `_testFingerDown`, `_testFingerUp`, `_testFingerMove` — most
  become methods on `*InputState` (still callable from tests, just
  `input._testKeyDown(&state, KEY_A)` instead of
  `input._testKeyDown(KEY_A)`).  Or just direct field writes since
  tests own the State.

`runtime.zig gestures`:
- `_testReset` — gone with module-level STATE.

## Ranked migration order (refines plan §3)

| Order | Subsystem | Vars | Files touched | Caller count (rough) |
|---:|---|---:|---|---:|
| 1 | `input` (Phase 3a) | 1 | runtime.zig + ui.zig + apps | ~40 |
| 2 | `time` / `window` / `fps` (Phase 3b — was core) | 4 | runtime.zig + drawing.zig + ui.zig + apps | ~80 |
| 3 | `gestures`, `camera` debug counter (Phase 3c) | 5 | runtime.zig | ~10 |
| 4 | `shapes`, `text`, `models` drawing internals (Phase 3c continued) | 10 | drawing.zig | ~30 |
| 5 | `sound` (Phase 3d) | 5 | sound.zig | ~50 |
| 6 | `rlgl` (Phase 3e — boss) | 6 | rlgl.zig + drawing.zig everywhere | ~400 |
| 7 | asset registry (Phase 3f) | — | drawing.zig | ~30 |

Total module-vars to retire: **31** (excluding the consolidation that
shrinks them — final count of `*State` types in `Runtime` will be
roughly 8-10, not 31).

## Sizing

Smallest unit (input STATE → InputState) probably resolves in one
session.  Boss fight (rlgl) is 3-4 sessions because every drawing.zig
primitive is a caller.  Total estimate from plan stands at 15-20
sessions; this inventory doesn't change it.

## Exit

No code changed.  Build state preserved.  874/874 tests, 90/90 smoke
green.  Phase 1a (InputState) starts next session.
