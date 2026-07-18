# Plan: raylib examples → zimr ports

A concrete, per-example port plan based on the **actual** raylib
master sources (217 examples in the uploaded snapshot, raylib 6.0+).
Supersedes the README-based draft at `raylib-port-plan.md` in the
work root — that one was built from the GitHub README and guessed
at LOC and engine touch surface; this one was built by reading the
217 `.c` files.

This plan answers three questions:

1. Of raylib's 217 examples, which ones do we **already cover**?
2. Of the rest, which are **worth porting** and which aren't (and
   why not)?
3. For the worth-porting set, in what **order** should they ship,
   and **what engine work** unlocks the blocked ones?

The plan does **not** answer "is this useful for zimr's users" —
the working assumption is that mirroring raylib's example coverage
is itself the goal, because (a) it makes zimr easy to learn for
anyone coming from raylib, and (b) writing the ports surfaces gaps
and bugs in zimr's API as we go.

---

## Inventory baseline

### What raylib has

```
core      49
shapes    41
textures  32
text      16
models    30
shaders   35
audio     11
others     3
────────────
total    217
```

LOC distribution (each `.c` file as it ships in `examples/`):

```
<100 LOC :  39 examples   easy ports, often <80 LOC zimr
100-150  :  84 examples   most common; ~120-180 LOC zimr
150-200  :  40 examples   medium effort
200-300  :  35 examples   meaningful turn each
>=300    :  19 examples   may need to split or trim
```

So **123 examples are <150 LOC** in C — those are the easy wins and
most should fit zimr's 250-LOC per-example soft limit even after
adding the prose-heavy comment style we've adopted.

### What zimr has (as of turn 157)

50 gallery entries.  Three on-disk `.zig` files are data-only
helpers (`gltf_simple_cube.zig`, `quad_glb_data.zig`,
`skinned_mesh_data.zig`) that aren't independent gallery apps.

Classifying the 50 against raylib categories:

- **Matches raylib closely (~25):** basic, keys, camera2d, cube3d,
  models3d, first_person_camera, split_screen, gestures_demo,
  gestures_testbed, window_demo, png_demo, load_image_demo,
  image_editor, image_text, procgen_noise, text_on_texture,
  texture_readback, particles, dynamic_mesh, text_layout,
  billboards, instancing, skybox, wireframe, gltf_simple,
  gltf_textured, gltf_model_refs, skinned_mesh, shader,
  shader_uniforms, rtt, mandelbrot, pbr_demo, mrt_demo,
  shapes_showcase, triangle_gradient, life, audio_basic,
  audio_stream_synth, composer_drum, music_streaming.
- **zimr-original, no raylib analog (10):** gallery (multi-app
  picker), ecs_solar_system, ecs_boids, physics_demo,
  physics_pyramid, imgui_demo, recursive_hud, rlsw_side_by_side
  (CPU rasterizer), touch_paint.

### The gap

```
raylib examples            217
  - already covered         50 (~25 close matches + ~25 zimr-leaning)
  - won't port              60 (sandbox impossible / dup / boilerplate)
  - port unblocked         ~85 (clearly worth doing now)
  - port engine-blocked    ~22 (need feature work first)
                          ────
                          ~217
```

Realistic landing target: **~135-150 examples** in the gallery (about
3× current) once the unblocked + blocked-after-engine-work are done.
Not 217 because of the 60-example won't-port bucket.

---

## zimr style for ports — what "in zimr style with lots of
## comments" means in practice

Before the batch tables, here's the contract every port should meet.
Mostly inferred from how `shapes_showcase.zig`, `physics_demo.zig`,
`keys.zig`, and `ecs_solar_system.zig` are written today — these are
the canonical zimr examples and what new ports should look like.

### File layout

```zig
// examples/<name>.zig — one-line summary.
//
// [Long-form what this demonstrates]
// [Why it's interesting / what to watch for]
// [Controls if interactive]
// [ASCII layout diagram if it's a multi-panel demo]
// [Caveats / non-obvious behaviour]
//
// [Relationship to other examples or zimr APIs touched]

const std = @import("std");
const z = @import("zimr");

const screen_w: c_int = 800;
const screen_h: c_int = 450;

const State = struct {
    frame_count: u64 = 0,
    // …app-specific fields with /// doc comments…
};

pub export fn main() void {
    z.run(.{
        .window = .{ .title = "zimr — <name>", .width = screen_w, .height = screen_h },
    }, State, initState, update) catch |err| {
        std.debug.print("zimr run failed: {s}\n", .{@errorName(err)});
        return;
    };
}

fn initState(_: *z.Frame) !State { return .{}; }

fn update(f: *z.Frame, state: *State) void {
    // [single-frame logic, heavily commented]
}
```

### Comment density

Look at `shapes_showcase.zig`'s top block: ~40 lines of prose
explaining *why* certain conventions exist (filled vs outline
shapes' texture argument, c_int vs f32 conventions).  That's the
target.  The comment isn't there to translate the code — it's there
to teach the reader what to notice.

raylib's C examples have headers like

```
*   raylib [shapes] example - bouncing ball
*   Example complexity rating: [★☆☆☆] 1/4
*   Example originally created with raylib 2.5, last time updated with raylib 2.5
```

We keep the "★/4 complexity rating" in the manifest (we already
have a `stars` field on each entry) but the prose in the top
comment is zimr-original, not a translation of the raylib header
boilerplate.  Reads better, surfaces what's actually interesting.

### Window size

raylib defaults to 800×450; zimr already follows that for almost
every example.  Keep it unless the port has a strong reason to
deviate (mandelbrot uses 800×600 to give the fractal more vertical
room, etc.).

### Color palette

zimr exposes `z.colors.*` with both raylib's named palette (RAYWHITE,
MAROON, …) and the Tailwind palette (slate_950, sky_500, …).  Ports
of raylib examples should keep raylib's named colors where the
original does — the visual continuity helps reviewers compare side-
by-side.  zimr-original demos use Tailwind because it scans better
against modern UIs.  Mixed is fine.

### Manifest entry

Each port needs an entry in `src/web/manifest.json`:

```json
{
  "name": "bouncing_ball",
  "module": "shapes",
  "stars": 1,
  "title": "Bouncing ball",
  "description": "Classic gravity + wall-bounce, two toggles via keyboard."
}
```

`module` mirrors raylib's category (core/shapes/textures/text/models/
shaders/audio).  `stars` mirrors raylib's complexity rating.

### Smoke test

Adding a name to `build.zig`'s `examples` array is enough — the
smoke harness picks it up automatically.  Smoke verifies the wasm
loads, runs ~30 frames without trapping, and emits some GL calls
(catches the most common breakage: missing init, dead pointer,
unhandled error).

### LOC budget

Soft 250.  Hard 350.  raylib examples that exceed 350 LOC in C
(text_3d_drawing, models_decals, text_unicode_emojis, rlgl_standalone,
shapes_top_down_lights, shapes_rectangle_advanced, etc.) need either
a trim of features or a split into two zimr examples that focus on
different aspects.  Each such case is flagged below.

---

## Per-category classification

Legend:

- `✓` already shipped in zimr (or close enough to skip)
- `✗ <reason>` won't port — sandbox/duplicate/boilerplate
- `⊕1` PORT, small (<150 LOC raylib, will fit easily in zimr)
- `⊕2` PORT, medium (150-300 LOC raylib)
- `⊕3` PORT, large (>300 LOC raylib, needs trim or split)
- `⊗ <feature>` BLOCKED on missing zimr engine feature

### core/ — 49 examples

```
core_2d_camera                    ✓  ← zimr camera2d
core_2d_camera_mouse_zoom         ⊕1 144 LOC, useful extension
core_2d_camera_platformer         ⊕2 307 LOC, will trim to ~200
core_2d_camera_split_screen       ✓  ← zimr split_screen handles this
core_3d_camera_first_person       ✓  ← zimr first_person_camera
core_3d_camera_fps                ⊕2 329 LOC, richer than ours; might supersede first_person_camera
core_3d_camera_free               ✓  ← zimr cube3d / models3d cover free cam
core_3d_camera_mode               ✓  ← zimr cube3d
core_3d_camera_split_screen       ✓  ← zimr split_screen
core_3d_picking                   ⊕1 120 LOC, exposes screen→world ray
core_automation_events            ⊗ automation API (defer; needs `automation.zig`)
core_basic_screen_manager         ✗ generic scene-state pattern, not engine-related
core_basic_window                 ✓  ← zimr basic
core_clipboard_text               ⊕1 164 LOC, DOM clipboard hook
core_compute_hash                 ⊕1 143 LOC, std.hash demo
core_custom_frame_control         ⊕1 141 LOC, exposes f.swap manually
core_custom_logging               ⊕1  90 LOC, hook z.log callbacks
core_delta_time                   ⊕1 111 LOC, dt visualizer
core_directory_files              ✗ no native fs in browser
core_drop_files                   ✗ sandbox (DOM has its own dnd API; different UX)
core_highdpi_demo                 ✗ native window manager
core_highdpi_testbed              ✗ native window manager
core_input_actions                ⊗ input-action remapping system
core_input_gamepad                ⊗ HTML5 Gamepad API integration
core_input_gestures               ✓  ← zimr gestures_demo
core_input_gestures_testbed       ✓  ← zimr gestures_testbed
core_input_keys                   ✓  ← zimr keys
core_input_mouse                  ⊕1  81 LOC, mouse HUD
core_input_mouse_wheel            ⊕1  64 LOC, scroll wheel HUD
core_input_multitouch             ⊕1  81 LOC, multitouch visualizer (already covered by touch_paint? confirm)
core_input_virtual_controls       ⊗ gamepad-like virtual stick (low priority)
core_keyboard_testbed             ⊕2 332 LOC, every-key matrix display
core_monitor_detector             ✗ native window manager
core_random_sequence              ⊕1 177 LOC, RNG visualizer
core_random_values                ⊕1  73 LOC, basic RNG calls
core_render_texture               ⊕1 100 LOC, basic RTT — overlaps with zimr rtt; do a focused minimal version
core_scissor_test                 ⊕1  78 LOC, scissor rect demo
core_screen_recording             ✗ native ffmpeg pipe
core_smooth_pixelperfect          ⊕1 149 LOC, NN-scaled RTT chain
core_storage_values               ✗ native fs (could do IndexedDB later as separate initiative)
core_text_file_loading            ✗ native fs
core_undo_redo                    ✗ generic CS pattern, not engine-related
core_viewport_scaling             ⊕2 320 LOC, fits-to-window with letterboxing
core_vr_simulator                 ⊗ WebXR (big separate initiative)
core_window_flags                 ✗ native window manager
core_window_letterbox             ⊕1 109 LOC, our own letterbox approach
core_window_should_close          ✗ native (browser has no "close" event in the same way)
core_window_web                   ✗ irrelevant — zimr IS the web build
core_world_screen                 ⊕1  87 LOC, place HUD over 3D point
```

**core totals:** 12 done, 12 skip, 18 port-unblocked, 7 blocked.
Plausible zimr core count after porting: **30** (up from 12).

### shapes/ — 41 examples

```
shapes_ball_physics               ⊕2 247 LOC — could use zimr's physics.zig
shapes_basic_shapes               ✓  ← zimr shapes_showcase covers this
shapes_bouncing_ball              ⊕1  93 LOC, canonical first port
shapes_bullet_hell                ⊕2 247 LOC, sprite/projectile soup
shapes_circle_sector_drawing      ⊕1  90 LOC, sector parameter tour
shapes_clock_of_clocks            ⊕2 204 LOC, grid of clocks → digit shapes
shapes_collision_area             ⊕1 117 LOC, AABB+circle overlap visualizer
shapes_colors_palette             ⊕1 105 LOC, named-color swatches
shapes_dashed_line                ⊕1  95 LOC, dash pattern parameter sweep
shapes_digital_clock              ⊕3 319 LOC, segment-based digit drawer — trim possible
shapes_double_pendulum            ⊕2 171 LOC, chaotic motion
shapes_easings_ball               ⊕1 116 LOC, falling ball with easings
shapes_easings_box                ⊕1 142 LOC, growing box with easings
shapes_easings_rectangles         ⊕1 124 LOC, grid of eased rects
shapes_easings_testbed            ⊕2 247 LOC, swap easing functions live
shapes_ellipse_collision          ⊕1 133 LOC, point-in-ellipse + ellipse-vs-ellipse
shapes_following_eyes             ⊕1 110 LOC, googly eyes
shapes_hilbert_curve              ⊕2 196 LOC, space-filling curve animation
shapes_kaleidoscope               ⊕2 172 LOC, mirror+rotate strokes
shapes_lines_bezier               ⊕1  87 LOC, drawSplineBezier showcase
shapes_lines_drawing              ⊕1 136 LOC, line variants
shapes_logo_raylib                ✗ raylib branding
shapes_logo_raylib_anim           ✗ raylib branding
shapes_math_angle_rotation        ⊕1 105 LOC, unit-circle visualizer
shapes_math_sine_cosine           ⊕1 176 LOC, live sine+cosine plot
shapes_mouse_trail                ⊕1 101 LOC, cursor history trail
shapes_penrose_tile               ⊕2 271 LOC, non-periodic tiling
shapes_pie_chart                  ⊕2 227 LOC, sector + labels
shapes_rectangle_advanced         ⊕3 358 LOC, edge+outline+interior styling — split
shapes_rectangle_scaling          ⊕1 104 LOC, drag-corner resize
shapes_recursive_tree             ⊕1 131 LOC, fractal branches
shapes_ring_drawing               ⊕1 101 LOC, drawRing parameter tour
shapes_rlgl_color_wheel           ⊕2 273 LOC, direct rlgl polygon
shapes_rlgl_triangle              ⊕1 168 LOC, raw vertex submission
shapes_rounded_rectangle_drawing  ⊕1  96 LOC, corner radius tour
shapes_simple_particles          ⊕2 284 LOC, simple 2D particle system
shapes_splines_drawing            ⊕2 288 LOC, four spline variants with handles
shapes_starfield_effect          ⊕1 145 LOC, warp speed
shapes_top_down_lights           ⊕3 382 LOC, tile-shadow caster — split or trim
shapes_triangle_strip            ⊕1 110 LOC, rlBegin TRIANGLE_STRIP
shapes_vector_angle              ⊕1 125 LOC, dot-product visualizer
```

**shapes totals:** 1 done, 2 skip, 34 port-unblocked, 0 blocked.
Plausible zimr shapes count after porting: **35**.  Shapes is the
fattest port arc — and the cleanest because there's no engine
work involved.

### textures/ — 32 examples

```
textures_background_scrolling     ⊕1  93 LOC, parallax 2 layers
textures_blend_modes              ⊕1 103 LOC, additive/multiply demo
textures_bunnymark                ⊕1 137 LOC, throughput benchmark
textures_cellular_automata        ⊕2 212 LOC, runs CA on Image — overlaps `life`; new variants
textures_clipboard_image          ⊗ DOM clipboard image API integration
textures_fog_of_war               ⊕2 161 LOC, RTT mask
textures_framebuffer_rendering    ⊕2 208 LOC, multi-FBO chain
textures_gif_player               ⊕1 122 LOC, animated GIF (needs decoder; zigimg has one)
textures_image_channel            ⊕1 112 LOC, per-channel extract
textures_image_drawing            ⊕1  98 LOC, draw into Image (CPU)
textures_image_generation         ⊕1 123 LOC, GenImage* procedural patterns
textures_image_kernel             ⊕1 145 LOC, convolution kernels
textures_image_loading            ⊕1  71 LOC — close to zimr load_image_demo; minimal variant
textures_image_processing         ⊕2 178 LOC, invert/grayscale/blur chain
textures_image_rotate             ⊕1  85 LOC, 90° + arbitrary rotation
textures_image_text               ✓  ← zimr image_text
textures_logo_raylib              ✗ branding
textures_magnifying_glass         ⊕1 134 LOC, zoom region under cursor
textures_mouse_painting           ⊕2 228 LOC, paint into texture
textures_npatch_drawing           ⊕1 116 LOC, 9-slice scaling
textures_particles_blending       ✓  ← zimr particles (close enough)
textures_polygon_drawing          ⊕1 138 LOC, textured convex polygon
textures_raw_data                 ✓  ← zimr texture_readback covers raw paths
textures_screen_buffer            ⊕1 153 LOC, RTT to screen-sized buffer
textures_sprite_animation         ⊕1 106 LOC, sprite sheet animation
textures_sprite_button            ⊕1 103 LOC, hover/press states with sprite
textures_sprite_explosion         ⊕1 126 LOC, frame-cycled animation
textures_sprite_stacking          ⊕1 104 LOC, fake-3D via stacked sprites
textures_srcrec_dstrec            ⊕1  88 LOC, src/dst rect explainer
textures_textured_curve           ⊕2 234 LOC, bezier ribbon with UVs
textures_tiled_drawing            ⊕2 256 LOC, tile-map renderer
textures_to_image                 ✓  ← zimr texture_readback
```

**textures totals:** 4 done, 1 skip, 26 port-unblocked, 1 blocked.

### text/ — 16 examples

```
text_3d_drawing                   ⊕3 695 LOC, text glyphs as 3D quads — split, trim, or skip features
text_codepoints_loading           ⊕1 165 LOC, custom glyph ranges
text_font_filters                 ⊕1 138 LOC, NN/bilinear/trilinear comparison
text_font_loading                 ✓  ← zimr text_layout covers font loading
text_font_sdf                     ⊗ SDF font support in zimr text module
text_font_spritefont              ⊕1  92 LOC, bitmap font from PNG
text_format_text                  ⊕1  68 LOC, printf-style — Zig std.fmt
text_inline_styling               ⊕2 287 LOC, bold/italic/color spans
text_input_box                    ⊕1 134 LOC, text input widget
text_rectangle_bounds             ⊕2 275 LOC, word-wrap inside rect
text_sprite_fonts                 ⊕1 111 LOC, sprite-font drawing
text_strings_management           ✗ generic strcmp/strstr/strtok demos
text_unicode_emojis               ⊕3 470 LOC, emoji rendering — trim heavily
text_unicode_ranges               ⊕2 205 LOC, custom codepoint ranges
text_words_alignment              ⊕1 134 LOC, left/center/right/justify
text_writing_anim                 ⊕1  68 LOC, typewriter effect
```

**text totals:** 1 done, 1 skip, 12 port-unblocked, 2 blocked (SDF font, 3D text needs depth-write).

### models/ — 30 examples

```
models_animation_blend_custom     ⊗ animation blending API
models_animation_blending         ⊗ animation blending API
models_animation_gpu_skinning     ✓  ← zimr skinned_mesh demonstrates GPU skinning
models_animation_timing           ⊗ animation system extension
models_basic_voxel                ⊕1 169 LOC, minecraft-style chunk
models_billboard_rendering        ✓  ← zimr billboards
models_bone_socket                ⊗ bone attachment API
models_box_collisions             ⊕1 127 LOC — could leverage zimr physics
models_cubicmap_rendering         ⊕1 101 LOC, grid-of-cubes from image
models_decals                     ⊕3 605 LOC, projected decal system — trim heavily
models_directional_billboard      ⊕1 117 LOC, sprite faces camera in axis-locked way
models_first_person_maze          ⊕1 139 LOC, cubicmap + FPS controller
models_geometric_shapes           ✓  ← zimr models3d
models_heightmap_rendering        ⊕1  91 LOC, grayscale → mesh
models_loading                    ✓  ← zimr gltf_simple / gltf_textured
models_loading_gltf               ✓  ← zimr gltf_simple
models_loading_iqm                ✗ obscure format, we have glTF
models_loading_m3d                ✗ obscure format, we have glTF
models_loading_vox                ✗ MagicaVoxel — separate initiative if needed
models_mesh_generation            ⊕2 189 LOC, procgen mesh sampler
models_mesh_picking               ⊕2 249 LOC, ray-vs-mesh
models_orthographic_projection    ⊕1 104 LOC, ortho cam mode
models_point_rendering            ⊕2 215 LOC, GL_POINTS at scale
models_rlgl_solar_system          ✓  ← zimr ecs_solar_system (different style but covers ground)
models_rotating_cube              ⊕1  94 LOC, basic spinning cube
models_skybox_rendering           ✓  ← zimr skybox
models_tesseract_view             ⊕1 128 LOC, 4D cube projected to 3D
models_textured_cube              ⊕2 246 LOC, manual UV mapping
models_waving_cubes               ⊕1 121 LOC, grid of cubes sin-wave height
models_yaw_pitch_roll             ⊕1 128 LOC, Euler vs quat visualizer
```

**models totals:** 7 done, 3 skip, 14 port-unblocked, 6 blocked
(all animation-blending or bone-socket related).

### shaders/ — 35 examples

```
shaders_ascii_rendering           ⊕1 121 LOC, ascii post effect
shaders_basic_lighting            ⊕1 144 LOC, Phong/Blinn
shaders_basic_pbr                 ✓  ← zimr pbr_demo
shaders_cel_shading               ⊕2 175 LOC, toon shader
shaders_color_correction         ⊕1 148 LOC, RGB curves post
shaders_custom_uniform           ✓  ← zimr shader_uniforms
shaders_deferred_rendering       ⊕3 343 LOC, deferred — needs MRT plumbing (we have mrt_demo)
shaders_depth_rendering          ⊕2 182 LOC, depth visualization
shaders_depth_writing            ⊕2 168 LOC, gl_FragDepth in custom shader
shaders_eratosthenes_sieve       ⊕1  99 LOC, GPU-side prime sieve
shaders_fog_rendering            ⊕2 162 LOC, depth-based fog
shaders_game_of_life             ⊗ compute shader (WebGL2 has no compute)
shaders_hot_reloading            ⊕1 137 LOC, file watcher — adapt for browser (URL fetch?)
shaders_hybrid_rendering         ⊕2 214 LOC, raymarch + raster combined
shaders_julia_set                ⊕2 203 LOC, fractal in fragment
shaders_lightmap_rendering       ⊕2 176 LOC, precomputed lighting texture
shaders_mandelbrot_set           ✓  ← zimr mandelbrot
shaders_mesh_instancing          ✓  ← zimr instancing
shaders_model_shader             ⊕1 108 LOC, per-model fragment shader
shaders_multi_sample2d           ⊕1 113 LOC, multi-texture blend
shaders_normalmap_rendering      ⊕2 173 LOC, normal-mapped lighting
shaders_palette_switch           ⊕1 157 LOC, colour-LUT post
shaders_postprocessing           ⊕2 182 LOC, bloom/blur/CRT chain
shaders_raymarching_rendering    ⊕1 119 LOC, SDF scene
shaders_rlgl_compute             ⊗ compute shader
shaders_rounded_rectangle        ⊕2 230 LOC, distance-field rounded rect
shaders_shadowmap_rendering      ⊕2 257 LOC, shadow map pass
shaders_shapes_textures          ⊕1 122 LOC, shader applied to shape texture
shaders_simple_mask              ⊕1 152 LOC, discard-by-alpha
shaders_spotlight_rendering      ⊕2 261 LOC, conical light volume
shaders_texture_outline          ⊕1 104 LOC, Sobel edge
shaders_texture_rendering        ⊕1  86 LOC, shader on a texture
shaders_texture_tiling           ⊕1 110 LOC, UV scaling
shaders_texture_waves            ⊕1 117 LOC, sinusoidal UV warp
shaders_vertex_displacement      ⊕1 121 LOC, vertex shader heightmap
```

**shaders totals:** 4 done, 0 skip, 28 port-unblocked, 2 blocked
(compute shader — WebGL2 limitation, can revisit if we add a WebGPU
backend).

### audio/ — 11 examples

```
audio_amp_envelope               ⊗ raygui (we have imgui) + audio_stream_callback
audio_mixed_processor            ⊗ audio DSP callback API
audio_module_playing             ✗ XM/MOD decoder (obscure format)
audio_music_stream               ✓  ← zimr music_streaming
audio_raw_stream                 ⊗ per-sample push callback API
audio_sound_loading              ✓  ← zimr audio_basic
audio_sound_multi                ⊕1  90 LOC, polyphony test
audio_sound_positioning          ⊕1 131 LOC, 2D pan + volume
audio_spectrum_visualizer        ⊕2 284 LOC, FFT viz — needs std.math FFT helper
audio_stream_callback            ⊗ audio callback API
audio_stream_effects             ⊗ DSP chain API
```

**audio totals:** 2 done, 1 skip, 3 port-unblocked, 5 blocked
(all need audio callback / DSP API additions to zimr's audio
module).

### others/ — 3 examples

```
embedded_files_loading           ⊕1 109 LOC, @embedFile demo
raylib_opengl_interop            ✗ native GL context interop
rlgl_standalone                  ✗ raylib's standalone-rlgl boilerplate
```

**others totals:** 0 done, 2 skip, 1 port-unblocked.

---

## Aggregate

```
                 done   skip   port   blocked   total
core              12     12     18       7        49
shapes             1      2     34       0        41 ★ biggest payoff
textures           4      1     26       1        32
text               1      1     12       2        16
models             7      3     14       6        30
shaders            4      0     28       2        35 ★ second-biggest
audio              2      1      3       5        11
others             0      2      1       0         3
────────────────────────────────────────────────────
total             31     22    136      23       217
```

Discrepancy with my opening "50 done": the table here counts only
the matches inside raylib's own categories.  zimr's 10 "originals"
(gallery, physics_demo, physics_pyramid, ecs_solar_system,
ecs_boids, imgui_demo, recursive_hud, rlsw_side_by_side,
touch_paint, image_editor's editor-features) don't map to raylib.
50 = 31 raylib-aligned + ~10 originals + a handful of zimr
variants on raylib themes.

**136 unblocked ports + 23 blocked.**  The blocked column is what
gates the rest:

```
gamepad input        →  3 examples unlock (gamepad/actions/virtual)
SDF font support     →  2 examples unlock (font_sdf, 3d_drawing depth)
automation events    →  1 example unlocks
animation blending   →  6 examples unlock (the models_animation_* set)
audio callback API   →  5 examples unlock (the audio DSP set)
compute shaders      →  2 examples unlock (game_of_life, rlgl_compute)
WebXR                →  1 example unlocks (vr_simulator)
DOM clipboard image  →  1 example unlocks (textures_clipboard_image)
                     ────
                       21 examples unlock via 8 distinct features
                       (+2 examples whose blocker is unclear)
```

---

## Suggested batch sequence

Each batch is sized to fit in roughly one turn (~5-10 examples) and
groups things that share infrastructure / require similar
documentation pattern / build on each other.

### Batch 1 — shapes warm-up (8 examples, all 1★)

Bring the easy shape primitives across.  No new infrastructure.
This is the obvious first batch because the LOC is small and the
result triples the gallery's "shapes" coverage immediately.

```
1. bouncing_ball          ( 93 LOC) — gravity + wall bounce + pause
2. lines_bezier           ( 87 LOC) — drawSplineBezier tour
3. lines_drawing          (136 LOC) — line variants
4. colors_palette         (105 LOC) — named-color swatches
5. collision_area         (117 LOC) — overlap predicates visualizer
6. vector_angle           (125 LOC) — dot product as angle
7. math_sine_cosine       (176 LOC) — live sine + cosine plot
8. math_angle_rotation    (105 LOC) — unit-circle visualizer
```

Each <200 LOC C → ~150-220 LOC zimr.  Total turn output: ~1500 LOC
spread across 8 files plus 8 manifest entries.  Easy to review.

### Batch 2 — shape easings (5 examples)

Cluster of easing-curve demos.  raylib's `reasings.h` is a small
header of easing functions; zimr can ship the equivalent as a
`src/easings.zig` module (a small one-off) or inline the formulas
per example.  I lean toward a tiny module — same formulas reused
across 5 examples, and it's a useful utility long-term.

```
1. easings_ball           (116 LOC) — falling ball
2. easings_box            (142 LOC) — growing/shrinking box
3. easings_rectangles     (124 LOC) — grid of eased rects
4. easings_testbed        (247 LOC) — swap easing function live
5. writing_anim           ( 68 LOC) — typewriter (text/ category but fits here)
```

Engine deliverable: `src/easings.zig` exposing
`easeInOutQuad`, `easeOutBounce`, etc. as plain `fn(t: f32) f32`.

### Batch 3 — shape playgrounds I (8 examples)

```
1. recursive_tree         (131 LOC) — fractal branching
2. ring_drawing           (101 LOC) — drawRing parameter tour
3. circle_sector_drawing  ( 90 LOC) — sector tour
4. rounded_rectangle_drawing ( 96 LOC) — corner radius tour
5. dashed_line            ( 95 LOC) — pattern + spacing
6. triangle_strip         (110 LOC) — rlBegin/rlEnd TRIANGLE_STRIP
7. following_eyes         (110 LOC) — googly eyes
8. mouse_trail            (101 LOC) — cursor history
```

### Batch 4 — shape playgrounds II (8 examples) ✅ shipped turn 169

```
1. double_pendulum        (171 LOC) — chaotic motion        ✅
2. starfield_effect       (145 LOC) — warp speed            ✅
3. simple_particles       (284 LOC) — 2D particles          ✅
4. rectangle_scaling      (104 LOC) — drag-corner resize    ✅
5. ellipse_collision      (133 LOC) — ellipse predicates    ✅
6. kaleidoscope           (172 LOC) — mirror+rotate strokes ✅
7. hilbert_curve          (196 LOC) — space-filling curve   ✅
8. ball_physics           (247 LOC) — bouncy-ball sandbox   ✅
```

### Batch 5 — shape art (5 examples)

```
1. penrose_tile           (271 LOC) — non-periodic tiling
2. pie_chart              (227 LOC) — sector + labels
3. clock_of_clocks        (204 LOC) — digit-forming grid
4. digital_clock          (319 LOC) — 7-segment digits, trim
5. splines_drawing        (288 LOC) — 4 spline types with handles
```

### Batch 6 — shape advanced (5 examples)

The fancy ones.  Save for last in the shapes arc; some need
splitting.

```
1. bullet_hell            (247 LOC) — sprite/projectile demo
2. top_down_lights        (382 LOC) — split into shadow-cast + light-volume
3. rectangle_advanced     (358 LOC) — split into edge+outline+interior
4. rlgl_triangle          (168 LOC) — raw rlBegin vertex submission
5. rlgl_color_wheel       (273 LOC) — direct polygon rlgl
```

After Batch 1-6: zimr shapes coverage goes from 3 → ~37.  Net: ~34
new examples in 6 turns.

### Batch 7 — core input gaps (6 examples, 1★ each)

```
1. input_mouse            ( 81 LOC) — mouse position + button HUD
2. input_mouse_wheel      ( 64 LOC) — scroll wheel
3. input_multitouch       ( 81 LOC) — multitouch HUD (verify not redundant with touch_paint)
4. random_values          ( 73 LOC) — RNG calls
5. random_sequence        (177 LOC) — RNG visualizer
6. delta_time             (111 LOC) — frame timing HUD
```

### Batch 8 — core cameras & rendering (6 examples)

```
1. 2d_camera_mouse_zoom   (144 LOC) — zoom-to-cursor 2D cam
2. 2d_camera_platformer   (307 LOC) — side-scroller with bounds; trim
3. 3d_picking             (120 LOC) — click → 3D ray
4. world_screen           ( 87 LOC) — HUD over 3D point
5. scissor_test           ( 78 LOC) — scissor rect demo
6. render_texture         (100 LOC) — minimal RTT (focused complement to zimr rtt)
```

### Batch 9 — core utilities (6 examples)

```
1. window_letterbox       (109 LOC) — fit-to-window letterboxing
2. viewport_scaling       (320 LOC) — richer letterboxing; trim
3. custom_frame_control   (141 LOC) — manual swap timing
4. custom_logging         ( 90 LOC) — hook z.log callbacks
5. compute_hash           (143 LOC) — std.hash demo
6. clipboard_text         (164 LOC) — DOM clipboard hook
```

### Batch 10 — core polish & 3D (4 examples)

```
1. 3d_camera_fps          (329 LOC) — supersedes first_person_camera (or sits beside it)
2. smooth_pixelperfect    (149 LOC) — NN-scaled RTT chain
3. keyboard_testbed       (332 LOC) — every-key matrix display; trim
4. basic_screen_manager   (skip — flagged as boilerplate, but reconsider for tutorial value)
```

After Batches 7-10: zimr core coverage goes from 12 → ~30.  Net:
~20 new examples in 4 turns.

### Batch 11 — texture manipulation (8 examples)

```
1. image_drawing          ( 98 LOC) — draw into CPU Image
2. image_processing       (178 LOC) — invert/grayscale/blur chain
3. image_generation       (123 LOC) — GenImage* procedural patterns
4. image_kernel           (145 LOC) — convolution kernels
5. image_channel          (112 LOC) — per-channel extract
6. image_rotate           ( 85 LOC) — 90° + arbitrary rotation
7. image_loading          ( 71 LOC) — minimal load variant
8. srcrec_dstrec          ( 88 LOC) — src/dst rect explainer
```

### Batch 12 — texture rendering (8 examples)

```
1. background_scrolling   ( 93 LOC) — parallax 2 layers
2. sprite_animation       (106 LOC) — sprite sheet animation
3. sprite_button          (103 LOC) — hover/press states
4. sprite_explosion       (126 LOC) — frame-cycled
5. sprite_stacking        (104 LOC) — fake-3D stacked sprites
6. blend_modes            (103 LOC) — additive/multiply
7. polygon_drawing        (138 LOC) — textured convex polygon
8. npatch_drawing         (116 LOC) — 9-slice scaling
```

### Batch 13 — texture advanced (6 examples)

```
1. magnifying_glass       (134 LOC) — zoom region under cursor
2. textured_curve         (234 LOC) — bezier ribbon
3. tiled_drawing          (256 LOC) — tile-map renderer
4. mouse_painting         (228 LOC) — paint into texture
5. fog_of_war             (161 LOC) — RTT mask
6. screen_buffer          (153 LOC) — RTT to screen-sized buffer
```

### Batch 14 — texture FX (4 examples)

```
1. bunnymark              (137 LOC) — throughput benchmark
2. cellular_automata      (212 LOC) — CA variants (Brian's Brain, etc.)
3. framebuffer_rendering  (208 LOC) — multi-FBO chain
4. gif_player             (122 LOC) — animated GIF (zigimg has decoder)
```

After Batches 11-14: textures from 4 → ~30.  ~26 new examples in 4 turns.

### Batch 15 — text & fonts unblocked (8 examples)

```
1. format_text            ( 68 LOC) — printf via std.fmt
2. writing_anim           (covered in Batch 2 already)
3. sprite_fonts           (111 LOC) — sprite-font drawing
4. font_spritefont        ( 92 LOC) — bitmap font from PNG
5. font_filters           (138 LOC) — NN/bilinear/trilinear
6. input_box              (134 LOC) — text input widget
7. codepoints_loading     (165 LOC) — custom codepoint ranges
8. words_alignment        (134 LOC) — left/center/right/justify
9. rectangle_bounds       (275 LOC) — word-wrap inside rect
10. unicode_ranges        (205 LOC) — custom codepoint ranges
11. inline_styling        (287 LOC) — bold/italic/color spans
```

(11 in this list because text/ is small and most are <200 LOC; can
split into two turns.)

### Batch 16 — models geometry (8 examples)

```
1. rotating_cube          ( 94 LOC) — basic spin
2. yaw_pitch_roll         (128 LOC) — Euler vs quat visualizer
3. orthographic_projection (104 LOC) — ortho cam
4. waving_cubes           (121 LOC) — grid sin-wave height
5. heightmap_rendering    ( 91 LOC) — grayscale → mesh
6. cubicmap_rendering     (101 LOC) — grid-of-cubes from image
7. first_person_maze      (139 LOC) — cubicmap + FPS controller
8. directional_billboard  (117 LOC) — axis-locked billboard
```

### Batch 17 — models advanced (6 examples)

```
1. box_collisions         (127 LOC) — leverage physics.zig AABB
2. basic_voxel            (169 LOC) — minecraft chunk
3. tesseract_view         (128 LOC) — 4D projection
4. textured_cube          (246 LOC) — manual UV mapping
5. mesh_generation        (189 LOC) — procgen mesh sampler
6. mesh_picking           (249 LOC) — ray-vs-mesh
7. point_rendering        (215 LOC) — GL_POINTS at scale
8. decals                 (605 LOC) — projected decal; trim heavily or skip
```

After Batches 16-17: models from 7 → ~22 examples.

### Batch 18 — shaders core (8 examples)

```
1. texture_rendering      ( 86 LOC) — shader on a texture
2. texture_outline        (104 LOC) — Sobel edge
3. texture_tiling         (110 LOC) — UV scaling
4. texture_waves          (117 LOC) — sinusoidal UV warp
5. multi_sample2d         (113 LOC) — multi-texture blend
6. shapes_textures        (122 LOC) — shader on shape texture
7. simple_mask            (152 LOC) — discard-by-alpha
8. eratosthenes_sieve     ( 99 LOC) — GPU prime sieve
```

### Batch 19 — shaders lighting (8 examples)

```
1. basic_lighting         (144 LOC) — Phong/Blinn
2. fog_rendering          (162 LOC) — depth-based fog
3. cel_shading            (175 LOC) — toon
4. normalmap_rendering    (173 LOC) — normal-mapped
5. lightmap_rendering     (176 LOC) — precomputed lighting
6. spotlight_rendering    (261 LOC) — conical volume
7. shadowmap_rendering    (257 LOC) — shadow map pass
8. model_shader           (108 LOC) — per-model fragment
```

### Batch 20 — shaders post & fractal (6 examples)

```
1. raymarching_rendering  (119 LOC) — SDF scene
2. julia_set              (203 LOC) — Julia fractal
3. ascii_rendering        (121 LOC) — ascii post
4. color_correction       (148 LOC) — RGB curves
5. palette_switch         (157 LOC) — colour-LUT
6. postprocessing         (182 LOC) — bloom/blur/CRT chain
```

### Batch 21 — shaders advanced (6 examples)

```
1. depth_rendering        (182 LOC) — depth visualization
2. depth_writing          (168 LOC) — gl_FragDepth manipulation
3. rounded_rectangle      (230 LOC) — distance-field rounded rect
4. vertex_displacement    (121 LOC) — vertex heightmap
5. hybrid_rendering       (214 LOC) — raymarch + raster combined
6. deferred_rendering     (343 LOC) — uses MRT; trim
7. hot_reloading          (137 LOC) — adapt for browser file fetch
```

After Batches 18-21: shaders from 6 → ~32 examples.

### Batch 22 — audio unblocked (3 examples)

```
1. sound_multi            ( 90 LOC) — polyphony
2. sound_positioning      (131 LOC) — 2D pan + volume
3. spectrum_visualizer    (284 LOC) — FFT viz; needs std FFT helper
```

---

## Engine-blocked summary

These deliveries gate the blocked column.  Each is a separate
feature initiative, NOT an "example" turn.  Most are well-scoped.

### gamepad input (3 examples unlocked)

Wire HTML5 Gamepad API into `src/input.zig`.  Connect/disconnect
events, axes, buttons.  Probably 1-2 turns.

Unlocks: `input_gamepad`, `input_actions`, `input_virtual_controls`,
plus `window_should_close` (uses gamepad to exit).

### SDF font support (2 examples unlocked)

Extend `src/text.zig` with SDF font loading + a paired shader.  raylib
ships a small SDF fragment shader and a `LoadFontEx` variant.
Probably 1 turn for the feature, 1 turn for examples.

Unlocks: `font_sdf`, `text_3d_drawing` (which uses SDF for crisp 3D
text edges).

### Audio callback API (5 examples unlocked)

Currently zimr's audio module exposes load/play/stream but no
per-sample callback.  raylib's `audio_raw_stream` writes samples
in a callback; `audio_mixed_processor`, `audio_stream_effects`,
`audio_stream_callback`, `audio_amp_envelope` all build on that.

Probably 2 turns: callback infrastructure + DSP helpers.

### Animation blending (6 examples unlocked)

`src/animation.zig` currently does single-clip skinned playback
(`skinned_mesh`).  raylib's 5.5+ skeletal-animation rebuild added
blending, GPU skinning, timing, bone-socket attachment.  zimr's
GPU skinning is already there; blending + timing + socket would
extend.  Probably 2 turns.

Unlocks: `animation_blend_custom`, `animation_blending`,
`animation_timing`, `bone_socket`, plus subtler upgrades to
existing `skinned_mesh`.

### Compute shaders (2 examples unlocked)

WebGL2 doesn't expose compute.  Would need a WebGPU backend.
This is a much bigger initiative — months — and not blocking the
other 130 ports.  Park it.

Unlocks: `game_of_life` (compute version), `rlgl_compute`.

### Automation events (1 example unlocked)

Record + replay input events.  `src/automation.zig`.  Probably half
a turn for the infrastructure.

Unlocks: `automation_events`.

### WebXR (1 example unlocked)

Big standalone initiative.  Park.

Unlocks: `vr_simulator`.

---

## Turn sequence — first 12 turns laid out concretely

Working assumption: do **Option B** from the previous plan
(category-batched).  Visible momentum per turn is high — the
gallery's "shapes" section grows by 8 in turn 158, by another 5
in turn 159, etc.

| Turn | Batch | Net new | Cum total | Hours est |
|---:|---|--:|--:|--:|
| 158 | Batch 1 — shapes warm-up (8 examples) | +8  | 58  | ~6 |
| 159 | Batch 2 — easings (5) + `src/easings.zig` | +5  | 63  | ~5 |
| 160 | Batch 3 — shape playgrounds I (8) | +8 | 71 | ~6 |
| 161 | Batch 4 — shape playgrounds II (8) | +8 | 79 | ~7 |
| 162 | Batch 5 — shape art (5)  | +5  | 84  | ~7 |
| 163 | Batch 6 — shape advanced (5 incl. 2 splits) | +5-7 | 89-91 | ~8 |
| 164 | Batch 7 + 8 — core input + cameras (12) | +12 | 101-103 | ~7 |
| 165 | Batch 9 — core utilities (6) | +6 | 107-109 | ~6 |
| 166 | Batch 10 — core polish (4) | +4 | 111-113 | ~5 |
| 167 | Batch 11 — texture manipulation (8) | +8 | 119-121 | ~7 |
| 168 | Batch 12 — texture rendering (8) | +8 | 127-129 | ~7 |
| 169 | Batch 13 — texture advanced (6) | +6 | 133-135 | ~7 |

After 12 example-porting turns: **~135 gallery entries**.

Continued turns (without detailed breakdown):

| Turn | Batch | Net new |
|---:|---|--:|
| 170-171 | Batch 14-15 — texture FX + text/fonts (15) | +15 |
| 172-173 | Batch 16-17 — models geometry + advanced (14-16) | +15 |
| 174-176 | Batch 18-20 — shaders (24) | +24 |
| 177 | Batch 21 — shaders advanced + Batch 22 — audio (10) | +10 |
| 178+ | Engine work: gamepad, SDF, audio callback, animation | +0 |
| 179+ | Engine-unblocked: gamepad examples, SDF examples, audio DSP, animation blending | +16 |

Grand total at end of arc: **~165-180 examples**.  Roughly 3× the
current count.

---

## Suggested next action — turn 158 batch

Start with Batch 1 — the 8 shape warm-ups.  Rationale:

- All <200 LOC of C, will be <250 LOC of zimr each.
- Zero engine work needed — zimr's `shapes.zig` API already
  handles every primitive these examples need.
- Tripling the gallery's shape coverage in one turn is visible
  user-facing momentum.
- Establishes the per-port template (manifest entry, smoke
  passes, CHANGELOG line) for everything that follows.

Concretely, turn 158 lands:

```
examples/bouncing_ball.zig
examples/lines_bezier.zig
examples/lines_drawing.zig
examples/colors_palette.zig
examples/collision_area.zig
examples/vector_angle.zig
examples/math_sine_cosine.zig
examples/math_angle_rotation.zig
```

Plus 8 entries in `build.zig`, 8 in `src/web/manifest.json`, one
CHANGELOG entry summarizing the batch.  All gates green.

---

## Locked decisions (turn 157 → 158 handoff)

All five sequencing questions answered.  These are the working
assumptions for the rest of the arc:

1. **Sequencing: B — category-batched.**  Finish all of shapes,
   then textures, then text, etc.  Each turn fills out one area
   visibly (e.g. shapes coverage 3 → 11 → 19 → 27 over four
   turns) rather than spreading 2 examples each across 4 areas.

2. **Assets: B — pure runtime fetch.**  Every example that needs
   binary assets fetches them from `examples/assets/<name>/` at
   init via `z.assets.fetchAll`-style helper (to be built).
   Standard pattern: an `Asset` state field that starts in
   `loading`, transitions to `ready` once all URLs resolve, then
   the example draws.  Smoke harness needs a fetch mock.
   **Implication: a small infra turn before Batch 11** (textures
   manipulation, around turn 167) builds the helper + the mock.
   Batches 1-10 don't need assets (they're shape/input/camera
   examples) so the infra slip is fine.

3. **Engine work: B — all unblocked examples first, then engine
   arcs at the end.**  136 unblocked ports ship across ~15 turns
   in the batches below; then 8 engine arcs each as their own
   focused initiative.  Blocked examples land in a final cluster
   after their feature lands.

4. **Gallery UI: A — preempt with category chips in turn 158.**
   Small HTML+JS change to `src/web/` reading the `module` field
   that's already in every manifest entry.  Lands alongside the
   8 example ports.  Every subsequent port turn lands into a
   gallery that's already organized by category.

5. **Physics polish: B — palate cleansers between batches.**
   Three standing items (thin-capsule spine inertia formula,
   visual sleep indicator, sleep thresholds on InitOptions)
   slot in roughly every 2-3 port batches as variety turns.
   Total combined work is under an hour spread across the arc.
   First palate-cleanser around turn 161.

---

## Turn 158 — concrete deliverables

The first port turn.  Establishes the per-port pattern that the
next 14 example-porting turns follow.

### Ships

```
examples/bouncing_ball.zig          ~140 LOC zimr  ★1
examples/lines_bezier.zig           ~130 LOC zimr  ★1
examples/lines_drawing.zig          ~180 LOC zimr  ★1
examples/colors_palette.zig         ~150 LOC zimr  ★2
examples/collision_area.zig         ~160 LOC zimr  ★2
examples/vector_angle.zig           ~170 LOC zimr  ★2
examples/math_sine_cosine.zig       ~220 LOC zimr  ★2
examples/math_angle_rotation.zig    ~140 LOC zimr  ★1
```

Total: 8 new examples, ~1290 LOC of new code.  None of them need
assets — all pure-draw shape demos — so the runtime-fetch infra
(decision 2) doesn't need to be built yet.

### Plus

- `build.zig` — 8 new entries in `examples` array.
- `src/web/manifest.json` — 8 new entries with `module: "shapes"`,
  `stars`, `title`, `description`.
- `src/web/<gallery picker>` — category chip row.  "All / core /
  shapes / textures / text / models / shaders / audio".  Clicking
  filters the list.  "All" by default.  Tiny CSS + JS change.
- `src/notes/CHANGELOG.md` — Turn 158 entry summarising the batch.

### Gates

All six green: `zig build test` (1185 → 1185), `zig build install`,
`zig build smoke-test` (50 → 58 PASS), `count_globals.py`,
`check_dag.py`, `zig fmt --check src/`.

### Per-port template (verbatim contract)

Each `examples/<name>.zig` file:

```
- Top comment block of 15-40 lines explaining what the example
  demonstrates, what to watch for, controls if interactive, and
  any non-obvious caveats.  See `shapes_showcase.zig` for tone.
- `const screen_w/screen_h: c_int = 800/450` unless deviating
  for a strong reason.
- `pub export fn main() void { z.run(...) catch ... }`
- `initState(_: *z.Frame) !State { return .{}; }`
- `update(f: *z.Frame, state: *State) void { ... }`
- raylib color palette (RAYWHITE, MAROON, ...) where the C
  source uses it; Tailwind colors only if we're adding our own
  aesthetic flourishes.
- LOC ceiling: soft 250, hard 350.
```

That's the contract.  Once turn 158 ships, every batch turn just
applies it 5-10 times.

