# Examples — what's there, what's next

zimr currently ships 15 examples, organized informally by what part
of the API they exercise.  This doc plans the next ~30 we'd want
to port, prioritized by what they prove out and what dependencies
they bring along.

## Current set (16)

| Example                | Proves                                      |
| ---------------------- | ------------------------------------------- |
| `basic`                | window + clear + a single texture           |
| `keys`                 | keyboard input state machine                |
| `life`                 | game-loop pattern, cellular automata        |
| `gallery`              | multi-app demo (4 sub-apps in 2×2)          |
| `particles`            | per-frame mutable state, RNG, color tinting |
| `shader`               | custom fragment shader                      |
| `shader_uniforms`      | shader uniform updates from CPU             |
| `rtt`                  | render-to-texture                           |
| `cube3d`               | 3D primitives + Camera3D                    |
| `models3d`             | sphere/cube/cylinder/cone draw + lighting   |
| `first_person_camera`  | mouse-look + WASD movement                  |
| `png_demo`             | embedded PNG decode + texture upload        |
| `load_image_demo`      | runtime fetch + async PNG decode            |
| `text_layout`          | TTF atlas + word wrap + measureEx           |
| `audio_placeholder`    | stub for the audio arc                      |
| `rlsw_side_by_side`    | rlsw `Context.clear` + `colorBufferBytes` upload to GL display texture (turn 98); plus `genTextures` / `bindTexture` / `texImage2D` / `texParameter` round-trip via a 64×64 procedural checker bound and waiting for the rasterizer (turn 101). |

## Coverage gaps (what's missing)

**Input.**  We have keyboard + mouse-look but no:
- Mouse picking (raycast a click into 3D)
- Mouse drag (pan / select / drag-and-drop pattern)
- Gamepad input (raylib has `IsGamepadButtonDown` etc.)
- Touch / multi-touch (raylib's `GetTouchPointCount` etc.)

**Camera2D.**  We have Camera3D but not Camera2D (zoom, pan,
rotate, screen-to-world).  Half a dozen raylib examples revolve
around this.

**Shapes drawing.**  We have `shapes.zig` but no example that
showcases the breadth — circle/triangle/polygon/line variants,
rounded rectangles, splines (Bezier/B-spline/Catmull-Rom which
all live in `shapes.zig`), collision detection.

**Image manipulation.**  We have many in-place operations
(resize, crop, rotate, blur, dither, color manipulation) but no
example exercises them.  This is a "show what's there"
opportunity.

**Text.**  Beyond `text_layout` we should show:
- Color-per-character animations (rainbow text, typewriter)
- Right-to-left rendering (raylib has Hebrew/Arabic example)
- Codepoint-aware wrapping (we have UTF-8 in `text.zig`)

**3D.**  Beyond cube/spheres:
- Heightmap / mesh generation
- Skybox / cubemap
- Simple lighting model (Phong / Blinn-Phong)
- Frustum culling demo
- Billboard rendering (always-face-camera quads)

**Shaders.**  Beyond two basic examples:
- Multi-pass post-processing (RTT chain)
- Compute-style fragment effects (Mandelbrot, raymarching)
- Custom vertex shader (waving flag, water surface)

**Audio.**  Deferred per the user's direction.

## Proposed next batch (Turns 21+)

Priority by "demonstrates the most surface for the least new
infra":

### Tier A — pure additions, no new infra

1. **`mouse_demo`** — cursor position, button state, scroll wheel,
   drag detection.  ~80 LOC.
2. **`shapes_showcase`** — rectangles (filled/lines/rounded),
   circles, triangles, polygons, line variants.  Touches every
   `shapes.zig` draw function.  ~150 LOC.
3. **`splines`** — Bezier (linear/quadratic/cubic) +
   Catmull-Rom + B-spline drawn from `shapes.zig`'s spline
   functions.  Drag-handle UI for control points.  ~200 LOC.
4. **`collisions`** — point-in-rect, point-in-circle,
   rect-rect, circle-rect overlap visualizers using
   `shapes.zig`'s collision predicates.  ~150 LOC.
5. **`camera2d`** — pan with mouse drag, zoom with scroll,
   screen↔world conversion.  Requires a small `camera.zig`
   addition for the 2D variant if it's not there yet.  ~120 LOC.
6. **`color_palette`** — visual swatches of every named color
   in `colors.zig` (raylib + Tailwind).  ~80 LOC.

### Tier B — needs zigimg integration (Turns 16-18)

7. **`image_formats`** — load JPEG, BMP, TGA, QOI, GIF using
   the new `loadImageFromMemory` after Turn 16.  Side-by-side
   render of all formats from a single decoder.  ~100 LOC.
8. **`image_editor`** — interactive resize/crop/rotate/blur on
   a loaded image, exporting back via `exportImage` after
   Turn 17.  Shows the in-place transform path.  ~250 LOC.

### Tier C — needs glTF dep (Turns 19-20)

9. **`gltf_loader`** — load a .glb file at runtime, draw with
   the existing 3D draw path.  Probably needs a small Zig glTF
   parser (zgltf or similar).  ~150 LOC.
10. **`skinned_mesh`** — bone animation playback.  Bigger lift,
   needs animation system.  ~400 LOC.

### Tier D — UI / interactivity

11. **`button_widget`** — minimal immediate-mode button:
    hovered, pressed, released states.  Foundation for any UI.
    ~100 LOC.
12. **`slider_widget`** — drag-to-adjust slider with click-on-
    track to set position.  ~120 LOC.
13. **`text_input`** — single-line text input with cursor +
    backspace + arrow keys.  Tests `getCharPressed` /
    `getKeyPressed`.  ~150 LOC.
14. **`menu_layout`** — keyboard-navigated menu with
    enter-to-select.  ~150 LOC.

### Tier E — graphics depth

15. **`mandelbrot`** — fragment-shader Mandelbrot with
    pan/zoom from mouse.  Pure GPU; no CPU per-pixel.  ~120 LOC.
16. **`raymarching`** — SDF raymarching scene in a fragment
    shader.  ~180 LOC.
17. **`postprocess`** — RTT chain with blur + bloom + tonemap
    passes.  Demonstrates multi-shader pipelines.  ~250 LOC.
18. **`heightmap`** — generate a mesh from a grayscale image,
    render with simple lighting.  ~200 LOC.
19. **`skybox`** — cubemap-textured background with proper
    perspective.  Needs a small `rlSetTexture` cubemap path.
    ~180 LOC.
20. **`billboard`** — quads that always face the camera, used
    as a particle / sprite renderer in 3D.  ~120 LOC.

### Tier F — math / physics demos

21. **`physics_balls`** — 100 bouncing balls with elastic
    collision against walls + each other.  Pure CPU.  ~200 LOC.
22. **`raycast_2d`** — light source casting shadows across a
    polygonal world.  Visibility polygon algorithm.  ~250 LOC.
23. **`pathfinding`** — A* on a grid with mouse-set
    start/goal.  Visualize the open/closed sets.  ~200 LOC.

## Sequencing

- Tier A is doable any time, no new dependencies.  Could land
  3-4 per turn after Turn 18 (zigimg arc done).
- Tier B fits naturally into Turns 16-18.
- Tier C goes in Turns 19-20 alongside glTF adoption.
- Tier D is a coherent UI sub-arc (~Turn 21-22) that builds a
  small immediate-mode-GUI vocabulary.
- Tiers E + F are nice-to-have showcases; pick a few that
  exercise current API and defer the rest.

Total: 23 candidate examples on top of the current 15 = 38.
About 1/4 of raylib's full example set.

## Selection principles

- **Each example is a focused proof.**  A single concept, well
  named, well documented in its header.  No "kitchen sink"
  examples.
- **Examples are smoke-tested.**  Adding a new example means
  adding it to `build.zig`'s `examples` list and verifying
  `smoke-test` passes for it.
- **Examples are < 300 LOC each, ideally < 200.**  Bigger than
  that and we should ask whether it belongs in the test suite
  instead.
- **Examples don't share state or helpers across files.**  Each
  is self-contained so users can copy-paste one and start
  iterating.
