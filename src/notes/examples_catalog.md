# Examples catalog — every example at a glance

Every directory under `examples/`, grouped by what it teaches rather than by the gallery's module, with a
one-line description and a verdict. Its first job is to show the examples side by side so duplicates
are visible. Most "duplicates" turn out to be a **simple version** of a fuller example — a first rung,
a single feature up close, a minimal repro — and those stay. Each one's description says what it is
the simple version of, and the fuller example's verdict lists its simple versions, so the relation
reads both ways. Only examples that are clearly redundant are deleted.

- **Sources.** The gallery's one-liners live in `src/web/manifest.json` (309 cards; the native
  `zimr_gallery` reads the same file). The descriptions below are rewritten from each example's own
  header comment, which is usually more accurate than the card. Where a card is wrong or a placeholder,
  the "Manifest fixes" section says so.
- **Columns.** ★ is the manifest's complexity stars, and "—" means the example is not in the gallery.
  LOC counts every `.zig` file in the example's directory.
- **Scope.** There are 333 directories; `assets/` and `example_common/` are shared support, not
  examples. That leaves **331 examples**: 309 in the gallery and 22 outside it.

## Verdicts

| Verdict | Meaning | Count |
| --- | --- | ---: |
| **KEEP** | stays | 324 |
| **DELETE** | clearly redundant: the same demo as another one, or a debugging step whose job is done | 5 |
| **MERGE → x** | folded into `x`, then deleted | 2 |

**KEEP (hidden)** stays in the tree but out of the gallery: a diagnostic or a reference, not a demo.
See "Hiding from the gallery" below.

How a description marks a relation:

- **Simple version of `x`** — a smaller program teaching part of what `x` teaches. It stays, as the
  first rung or the minimal repro.
- **Sibling of `x`** — the same family, but a different technique or a different take; neither
  contains the other.
- **Focused version of `x`'s tab** — one tab of a tour (`ui_full_showcase`) as its own program.

## Reviewed with Simon (Oct 12, 2026)

**Round 1** — the ten most arguable deletes of the first draft, decided one at a time:

| Example | Decision |
| --- | --- |
| shared_smoke, tile_smoke, sort_smoke | Fold into one probe page (`compute_probe`) running every check, hidden from the gallery |
| mpc_quadruped | Keep, visible, with its honest "nothing holds yet" status |
| bridge_slice | Keep, hidden: the reference for the bridge's DOM verbs |
| cube_demo | Keep: the one-UBO rung before `lambert_demo` |
| pipeline_rendertarget | Delete |
| first_person_camera | Keep; mouse-look direction fixed and pointer lock added |
| julia | Delete |
| split_screen | Keep: the local-multiplayer split-screen pattern |
| input_virtual_controls | Keep: the minimal on-screen D-pad |
| net_rtc_smoke | Keep, hidden: the middle layer of the network diagnostics |

**Round 2** — Simon kept the next ten (decal_sw, skinned_mesh, vertex_texture_test, cube3d, basic,
text_field, ui_tables_basic, imgui_phone_demo, ui_notes_phone, bridge_classic_probe) and set the rule
this catalog now follows: **delete only what is clearly redundant**, and keep a simple version of
another example, saying so in its description. The first draft's other 41 deletes and 58 merges were
re-read under that rule; only three are clearly redundant (`ui_minimal_one_context`, `ui_log_skeleton`,
`ui_mini_plot_smoke`).

## Hiding from the gallery

Today the gallery is opt-in: `src/web/manifest.json` is written by hand, and an example without a
card is simply absent, with nothing to say so. That is how 19 examples are missing now, among them
`zimrnum_train`, `ragdoll_compare` and `cartpole_duel`.

Simon wants it the other way round, every example visible unless it opts out:

- the `App` row in `build.zig`'s `wgpu_apps` table gains a flag, for example `.gallery = .hidden`;
- a build check fails when a visible row has no manifest card, so an example can no longer vanish
  by omission;
- `zimr_gallery` and the web gallery both read the manifest, so neither needs to know about the flag.

Hidden by decision so far: `compute_probe` (from the three smokes), `bridge_slice`, `net_rtc_smoke`,
plus the internal `wgpu_bringup`. When the switch lands, each of the other examples now outside the
gallery needs a show-or-hide call.

## Families: the full example and its simpler versions

| Family | Full version | Simple versions and siblings |
| --- | --- | --- |
| Hello world | hello_world | basic (rl-immediate), draw2d_demo (the draw2d sink), shapes_demo; wgpu_bringup (internal) |
| One shader on CPU, GPU and comptime | helmet_sw, shadowmap_sw, rt_sidebyside, mandel_sidebyside, four_ways | cube_sidebyside, shadow_sidebyside, rt_shader (simple versions); decal_sw, sidebyside (siblings) |
| Fractals | mandel_julia, mandel_sidebyside | comptime_mandelbrot, comptime_julia, julia_gallery |
| Path tracers | rt_workers, rt_sidebyside | raytracer (CPU, with an editable scene), rt_shader (GPU half alone) |
| Painting | textures_mouse_painting | lines_drawing, touch_paint (siblings); input_multitouch (simple) |
| Keyboard and mouse | keys | input_keys, input_mouse, input_mouse_wheel |
| On-screen controls | input_actions | input_virtual_controls |
| Gestures | gestures_testbed | gestures_demo; ui_phone_gestures (hand-rolled on raw input) |
| Easing | easings_testbed | easings_ball, easings_box, easings_rectangles (scripted sequences) |
| 2D primitives | shapes_showcase | circle_sector_drawing, ring_drawing, rounded_rectangle, rectangle_advanced, dashed_line, triangle_gradient, triangle_strip (one primitive up close each), shapes_demo |
| Immediate 3D scene | models3d | cube3d, 3d_probe (simple); camera_controls (the orbit camera) |
| Mesh generators | models_geometric_shapes | shapes_gallery, platonic_solids, icosphere_demo (siblings); wireframe (simple) |
| Model loading | obj_bunny | obj_simple, gltf_simple, gltf_textured |
| The damaged helmet | damaged_helmet, helmet_sw | pbr_demo (simple) |
| Hand-wired 3D | lambert_demo | cube_demo |
| Skinning | bone_socket | skinned_mesh (simple); models_animation_blend_custom (sibling) |
| First-person | fps_playground, first_person_maze | first_person_camera (simple); cubicmap (the maze, orbited) |
| CPU image to texture | image_editor | png_demo, textures_image_rotate, textures_image_channel, textures_raw_data, textures_image_text |
| Sprite sheets | srcrec_dstrec | textures_sprite_animation, textures_sprite_button, textures_sprite_explosion |
| Render once, composite many | render_texture | recursive_hud |
| One world, two cameras | textures_framebuffer_rendering | split_screen |
| Fonts | text_layout, text_font_sdf, text_unicode_ranges | text_font_loading, text_font_filters, text_codepoints_loading |
| Text fields | ui_text_editing, ui_input_callbacks | text_field, ui_code_editor, ui_input_flags_zoo_phone, ui_notes_phone (an app) |
| UI starters | ui_demo | ui_smoke_button, ui_minimal_button |
| UI tour | ui_full_showcase | ui_widgets_data_types, ui_plotting_basic, ui_custom_rendering, ui_polish (one tab each); imgui_phone_demo (phone layout); ui_primitives_zoo_phone |
| Tables | ui_tables_demo | ui_tables_basic, ui_tables_scroll (simple); ui_kanban_board, ui_data_grid_phone (siblings) |
| Drag and drop | ui_drag_drop_demo | ui_drag_drop_source (simple); ui_drag_drop_flags_tour (sibling) |
| Docking and persistence | ui_dock_basic, state_persistence | ui_dock_simple, ui_persistence (simple); ui_dock_persistence (sibling) |
| Log viewers | ui_log_viewer | ui_clipper (sibling) |
| Plots | plot_demo, plot3d_demo | ui_plot (simple); plot3d_gallery (sibling) |
| Double pendulum | robot_sidebyside, double_pendulum | robot_pendulum (simple) |
| CPU particles | particles | simple_particles (sibling) |
| Starfield | starfield_effect | starfield (simple) |
| GPU compute probes | compute_smoke | sort_smoke, shared_smoke, tile_smoke (folding into one hidden `compute_probe`) |
| Network | net_cursors | net_ws_smoke, net_rtc_smoke (the layers under it) |
| Motion tracking, one page per robot | geno_track, getup_train, track_train | dance_track, geno_ppo, geno_train (the same pages on the other robot) |

## Catalog

### App shell and starters

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| hello_world | 3 | 104 | "Hello, World!" in the default font on a plain background: the smallest app that draws text. | KEEP |
| basic | 1 | 103 | A pulsing background and one checker-textured triangle through raylib's rl-immediate API (`rlBegin`, `rlTexCoord2f`, `rlVertex2f`). If it shows, the whole WebGPU path works. | KEEP — the smallest rl-immediate example |
| shapes_demo | 3 | 148 | **Simple version of `shapes_showcase`:** a rectangle, two circles, a texture and text through `WgpuGl` — the first 2D drawing on WebGPU. | KEEP |
| draw2d_demo | 1 | 93 | `sink.rect`, `sink.circle` and `sink.image` on the unified draw2d surface: the smallest use of the sink API. | KEEP |
| wgpu_bringup | — | 393 | The first wgpu app: rectangles and a triangle on hand-written WGSL, on the classic `_initialize` + `update(dt)` contract. The tier-a smoke set and `zig build standalone` build it. | KEEP (internal) |
| delta_time | 1 | 111 | A ball crosses the screen at a constant real speed by scaling its step by `f.time.delta_time`; frame-time and FPS readout. | KEEP |
| random_sequence | 1 | 116 | A Fisher–Yates shuffle from a PRNG held in `State`, drawn as a rainbow bar chart; Space reshuffles. | KEEP — simple version: `random_values` |
| random_values | 1 | 89 | **Simple version of `random_sequence`:** one ranged random integer every two seconds from a PRNG held in `State`. | KEEP |
| scissor_test | 2 | 163 | A fill and a line of text clipped to a finger-dragged box by the GPU scissor rect; also shows submitting the UI before asking `wantCaptureMouse`. | KEEP |
| undo_redo | 2 | 230 | Snapshot undo and redo over an edited string, from word buttons or typed keys (`getCharPressed`). | KEEP |
| state_persistence | 2 | 177 | A plain struct through `z.serialize` and `z.saveValue`, surviving a page reload (browser storage) or a restart (an app-data file). | KEEP — the app-level persistence reference |

### Multi-app hosts and infrastructure

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| launcher | 3 | 250 | The flagship switcher: 32 full examples booted lazily, one shown fullscreen at a time, each with its own leak-checking allocator. | KEEP |
| gallery_all | 3 | 256 | `z.Launcher` hosting four inline child apps in a 2×2 grid; tap a cell to deinit, leak-check and re-init it; reflow versus scale-to-fit placement. | KEEP (flagship) — hand-rolled version: `gallery` |
| gallery | 3 | 266 | **Hand-rolled version of `gallery_all`:** four sub-apps in a 2×2 grid through `pushViewport`/`popViewport`, without the Launcher. | KEEP |
| zimr_gallery | — | 311 | The native gallery: lists `manifest.json` and starts each example's `.exe` as its own process, showing how it exited. | KEEP (infrastructure) |
| profiler_flamegraph | 1 | 183 | The integrated profiler's flamegraph on pretend frame work: nested zones that spin, a level-load hitch once a second, the panel pinned to the worst recent frame. | KEEP |
| bridge_slice | — | 132 | A wasm app that builds its whole page (CSS, prose, an iframe, two WebGPU canvases) through the bridge's DOM verbs. | KEEP (hidden) — the only reference for the DOM verbs and several canvases on one device |
| bridge_classic_probe | — | 274 | A validator for the classic `_initialize` + `update(dt)` contract on the Zig bridge, counted against a mock device. | KEEP — not in the gallery, like `bridge_slice`; checks the contract `wgpu_bringup` still uses |

### Input and platform

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| keys | 1 | 194 | WASD or arrows move a square (Shift for speed), Space toggles the background, a mouse crosshair and click splats. | KEEP — simple versions: `input_keys`, `input_mouse`, `input_mouse_wheel` |
| input_keys | 1 | 127 | **Simple version of `keys`:** arrow keys move a ball — `isKeyDown` and nothing else. | KEEP |
| input_mouse | 1 | 148 | **Simple version of `keys`' mouse half:** a ball follows the cursor; each of the seven mouse buttons sets a colour; H hides the cursor. | KEEP |
| input_mouse_wheel | 1 | 106 | **Simple version of `keys`' mouse half:** the wheel moves a box — `getMouseWheelMove` alone. | KEEP |
| input_multitouch | 1 | 116 | **Simple version of `touch_paint`:** one circle per finger, labelled with its touch slot. | KEEP |
| touch_paint | 2 | 185 | Multi-touch finger painting, one colour per touch id. A sibling of `textures_mouse_painting` and `lines_drawing`. | KEEP — simple version: `input_multitouch` |
| input_actions | 2 | 470 | Named actions bound to keys, pads and touch; game logic reads actions, never keys, and the input scheme switches live. | KEEP — simple version: `input_virtual_controls` |
| input_virtual_controls | 2 | 213 | **Simple version of `input_actions`' PAD scheme:** an on-screen D-pad drives a ball by touch or mouse hold. | KEEP |
| gestures_testbed | 3 | 200 | Per-finger touch state, the gesture state machine and a transition log. | KEEP — simple version: `gestures_demo` |
| gestures_demo | 2 | 162 | **Simple version of `gestures_testbed`:** the last recognized gesture (drag, pinch, hold) with its data and a history. | KEEP |
| ui_phone_gestures | 3 | 214 | Tap targets, a drag handle and a swipe-scrolled list hand-rolled on raw touch input — no widgets, despite the `ui_` name. A sibling of `gestures_testbed`. | KEEP |
| input_gamepad | 2 | 141 | Each gamepad slot: buttons lit while held, sticks, triggers; the south button rumbles. | KEEP |
| input_pointer_lock | 2 | 165 | Click to lock the pointer and turn a view by mouse delta; shows lock, presence, focus and the delta. | KEEP |
| input_cursor_shapes | 2 | 133 | Hover a tile to set the cursor's shape, or hide it; the window title names the shape. | KEEP |
| ui_input_query_demo | 2 | 135 | A live readout of every key in `InputSnapshot`, the mouse, the modifiers and the `wantCapture*` flags. | KEEP — the input diagnostic |
| monitors | 2 | 135 | The monitors the platform reports (name, position, size, scale, refresh); natively, keys centre, minimize, maximize and size-limit the window. | KEEP |
| window_requests | 2 | 152 | Buttons that ask the platform for fullscreen, keep-awake, an opened URL, and clipboard copy and paste. | KEEP |
| viewport_scaling | 2 | 184 | Render at a fixed 640×360, letterbox it into any window, and map the mouse back into virtual coordinates. | KEEP — sibling: `smooth_pixelperfect` |
| smooth_pixelperfect | 2 | 142 | **Sibling of `viewport_scaling`:** the same low-res render target (320×180) scaled up, here scrolled smoothly by sub-pixels while staying pixel-perfect. | KEEP |

### 2D drawing

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| shapes_showcase | 2 | 173 | A grid of animated 2D primitives: lines, rectangles, circles, polygons, fans, gradients, sectors, ellipses, splines, dashes. | KEEP — simple versions, one primitive up close with live parameters: `circle_sector_drawing`, `ring_drawing`, `rounded_rectangle`, `rectangle_advanced`, `dashed_line`, `triangle_gradient`, `triangle_strip`; also `shapes_demo` |
| circle_sector_drawing | 2 | 134 | **One `shapes_showcase` primitive up close:** a sector whose angle, radius and segment count animate; tap to see the tessellation's vertices. | KEEP |
| ring_drawing | 2 | 124 | **One `shapes_showcase` primitive up close:** an annulus with breathing angles and radii, cycling filled, outline and sector-outline. | KEEP |
| rounded_rectangle | 2 | 118 | **One `shapes_showcase` primitive up close:** a rounded rectangle with animated roundness, size, outline and segment count. | KEEP |
| rectangle_advanced | 2 | 195 | **One `shapes_showcase` primitive up close:** rounded rectangles with separate left and right corner radii and a horizontal gradient. | KEEP |
| dashed_line | 2 | 151 | **One `shapes_showcase` primitive up close:** a dashed line aimed at the pointer, its dash and gap lengths breathing. | KEEP |
| triangle_gradient | 1 | 88 | **One `shapes_showcase` primitive up close:** three triangles whose per-vertex colours pulse out of phase. | KEEP |
| triangle_strip | 2 | 131 | **One `shapes_showcase` primitive up close:** a gear built from a triangle strip, a hue per triangle; drag to set the segment count. | KEEP |
| splines_drawing | 2 | 176 | Linear, B-spline, Catmull-Rom and Bezier curves over the same draggable points. | KEEP — simple version: `lines_bezier` |
| lines_bezier | 1 | 118 | **Simple version of `splines_drawing`'s Bezier mode:** a cubic Bezier with drifting control points and its dashed control polygon. | KEEP |
| math_sine_cosine | 2 | 122 | The unit circle with cos and sin as the triangle's legs, and the two waves traced below. | KEEP — simple version: `math_angle_rotation` |
| math_angle_rotation | 1 | 83 | **Simple version of `math_sine_cosine`:** fixed lines at 0, 30, 60 and 90 degrees, and one line sweeping round. | KEEP |
| vector_angle | 2 | 90 | The signed angle between two vectors, or between a ray and the horizontal, with zimrmath's helpers. | KEEP |
| color_wheel | 2 | 179 | An HSV wheel drawn as a triangle fan, with a draggable picker, a value slider and a hex swatch. | KEEP |
| colors_palette | 2 | 168 | raylib's 21 named colours as hoverable swatches: the `Color.x` constants. | KEEP |
| logo_raylib_anim | 2 | 192 | raylib's framed-square logo assembled by a small state machine: blink, grow the bars, type the letters, fade. | KEEP — simple version: `logo_raylib` |
| logo_raylib | 2 | 82 | **Simple version of `logo_raylib_anim`:** the same logo drawn still from primitives, rebadged "zimr". | KEEP |
| following_eyes | 2 | 108 | Googly eyes tracking the pointer with atan2 and a radius clamp, wandering when idle. | KEEP |
| collision_area | 2 | 191 | A bouncing box and a mouse box, with their AABB intersection drawn. | KEEP — sibling: `ellipse_collision` |
| ellipse_collision | 2 | 244 | **Sibling of `collision_area`:** point-in-ellipse and ellipse–ellipse tests, the ellipses resizable from a panel. | KEEP |
| rectangle_scaling | 2 | 104 | Drag a corner handle to resize a rectangle: idle, ready and dragging states. | KEEP |
| pie_chart | 2 | 163 | A live pie chart: breathing values, the hovered slice pops out, percentage labels, a donut toggle. | KEEP |
| clock_of_clocks | 2 | 200 | The time as HHMMSS, each digit a 4×6 grid of tiny analog clocks whose hands sweep between digits. | KEEP — sibling: `digital_clock` |
| digital_clock | 2 | 221 | **Sibling of `clock_of_clocks`:** a seven-segment readout and an analog dial showing the real local time. | KEEP |
| camera2d | 2 | 94 | Camera2D's offset, target, zoom and rotation on a self-animating pan, zoom and turn. | KEEP |

### Generative 2D

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| fractal_tree | 3 | 92 | A recursive tree swaying in the wind, with blossoms at the tips. | KEEP — slider version: `shapes_procedural`'s tree mode |
| shapes_procedural | 2 | 223 | Two modes: a branching tree with angle, length and decay sliders (**`fractal_tree` with sliders**), and a fading pointer trail (**a simple version of `trails`**). | KEEP |
| penrose_tile | 2 | 203 | A Penrose tiling from an L-system read as turtle commands, one generation per tap. | KEEP |
| hilbert_curve | 3 | 234 | An animated Hilbert curve of order 2 to 6, its hue sweeping along the path. | KEEP |
| kaleidoscope | 2 | 117 | A self-driven brush mirrored twelve ways about the centre, leaving a fading rainbow trail. | KEEP |
| starfield_effect | 2 | 178 | Warp-speed stars with a "Warp drive" panel: speed, lines or circles, trail, colour. | KEEP — simple version: `starfield` |
| starfield | 3 | 122 | **Simple version of `starfield_effect`:** the same warp-speed stars projected by 1/z, with no panel. | KEEP (flagship) |
| bullet_hell | 2 | 186 | Radial bullet volleys whose angle creeps each frame, so the rings braid into spirals. | KEEP |
| trails | 3 | 111 | Lissajous emitters drawn into a render texture that is faded, never cleared: render-texture accumulation. | KEEP |
| textures_mouse_painting | 2 | 119 | Paint on a persistent render-texture canvas with a colour palette. | KEEP — siblings: `lines_drawing`, `touch_paint` |
| lines_drawing | 1 | 106 | **Sibling of `textures_mouse_painting`:** paint into a render-texture canvas with a hue cycled by stroke speed; right-drag erases, the wheel sets thickness. | KEEP |

### 2D simulation and games

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| ball_physics | 2 | 315 | Up to 5000 grabbable bouncing balls, with gravity, friction and elasticity in a panel, and a shake button. | KEEP — simple version: `bouncing_ball` |
| bouncing_ball | 1 | 168 | **Simple version of `ball_physics`:** one ball under gravity bouncing off the walls; G toggles gravity, Space pauses. Filed under "physics". | KEEP |
| double_pendulum | 2 | 221 | Two chaotic double pendulums started 1e-3 rad apart, diverging, with fading trails. | KEEP |
| particles | 3 | 173 | A CPU particle fountain with an ImGui panel (rate, gravity, size); drag the emitter. | KEEP — sibling: `simple_particles` |
| simple_particles | 2 | 188 | **Sibling of `particles`:** a ring-buffer emitter cycling water, smoke and fire particle types, self-running. | KEEP |
| life | 1 | 247 | Conway's Life: paint cells, pause, clear, randomize, set the speed. | KEEP |
| cellular_automata | 3 | 219 | Wolfram's 1-D rules (30, 90, 110…), streamed to the GPU as a CPU framebuffer. | KEEP |
| langton_ant | 2 | 607 | Langton's ant building its highway, its last ten turns drawn so the rule can be read off the screen; pan, zoom, single-step. Filed under "compute". | KEEP (flagship) |
| ecs_boids | 3 | 245 | Reynolds flocking on the ECS (archetypes, iterator, forEach), with sliders and a mouse repel. | KEEP |
| ecs_solar_system | 4 | 450 | An ECS node tree with tags and a CmdBuf: sun, planets, moons, ships and their orbits. | KEEP |
| snake | 1 | 450 | Snake, by keyboard or by swipe, filling any window. | KEEP (flagship) |
| tic_tac_toe | 1 | 274 | Two players share the screen; the board, X and O are all 2D shapes. | KEEP (flagship) |
| goban | 3 | 5335 | Go and Atari Go: each group a tree of stones whose root keeps its liberties; a dragged stone shows the liberties it would leave and the stones it would take; captures fly to the side; a debug panel with the forest drawn, a judge, a move log and diagrams to copy and paste. | KEEP (flagship) |
| goban_outposts | 2 | 38 | goban made another way (`goban.appFor`): Atari Go on 8 x 8 against the computer, a ladder of games (each rung played moving first, then second; won moving second, it gives the computer an outpost or takes one of the person's), no interface, a won game restarting by itself. | KEEP |
| goban_problems | 2 | 33 | goban made another way (`goban.appFor`): its kill problems against the computer, the problem's region of the board, random symmetries, Undo and Next. | KEEP |
| go_puzzles_hero | 2 | 42 | goban made another way (`goban.appFor`): fights on the outpost ladder, life and kill puzzles in turn, each puzzle a ladder of starts - abandoned down, solved up. | KEEP |

### Animation and easing

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| easings_testbed | 3 | 333 | Pick any easing for X and for Y and watch a ball travel the combined path. | KEEP — scripted versions: `easings_ball`, `easings_box`, `easings_rectangles` |
| easings_ball | 2 | 208 | **Scripted version of `easings_testbed`:** a three-stage ball animation through elasticOut, elasticIn and cubicOut. | KEEP |
| easings_box | 2 | 193 | **Scripted version of `easings_testbed`:** a five-stage box animation touring five curves. | KEEP |
| easings_rectangles | 3 | 158 | **Scripted version of `easings_testbed`:** a 16×9 grid of rectangles shrinking with circOut while spinning linearly; also a light stress test of rotated-rectangle batching. | KEEP |
| ui_animation_gallery | 3 | 213 | The UI's own tweens (`u.animated`, six curves side by side) and an interruptible spring (`u.spring`). | KEEP — a different API from `z.easings` |

### Textures and images

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| image_editor | 3 | 186 | The CPU image API: decode a PNG, copy it, blur, invert and rotate the copies, and rewrite one texture every frame with `updateTexture`. | KEEP — simple versions, one CPU image operation each: `png_demo`, `textures_image_rotate`, `textures_image_channel`, `textures_raw_data`, `textures_image_text` |
| png_demo | 2 | 94 | **Simple version of `image_editor`:** decode an embedded PNG, upload it, draw it four times tinted. | KEEP |
| textures_image_rotate | 1 | 95 | **Simple version of `image_editor`:** rotate the logo on the CPU by three arbitrary angles at load and cycle the results. | KEEP |
| textures_image_channel | 2 | 117 | **Simple version of `image_editor`:** split a PNG into its R, G, B and A channels and lay them out tinted over a checkerboard. | KEEP |
| textures_raw_data | 1 | 126 | **Simple version of `image_editor`:** build a texture from a hand-filled RGBA buffer, next to a decoded PNG. | KEEP |
| textures_image_text | 2 | 90 | **Simple version of `image_editor`:** rasterize text into a CPU image so the caption is baked into the texels before upload. | KEEP |
| procgen_noise | 3 | 159 | White, Perlin and cellular noise images from `genImage*`, plus a scrolling Perlin field. | KEEP |
| textures_screen_buffer | 2 | 148 | A CPU palette-cycling fire in an index buffer, mapped through an HSV palette and uploaded each frame. | KEEP |
| srcrec_dstrec | 2 | 242 | One frame's source sub-rect of a sprite sheet mapped onto a scaled, rotated destination rect. | KEEP — simple versions: `textures_sprite_animation`, `textures_sprite_button`, `textures_sprite_explosion` |
| textures_sprite_animation | 1 | 83 | **Simple version of `srcrec_dstrec`:** a six-frame sprite sheet cycled at a fixed speed. | KEEP |
| textures_sprite_button | 1 | 79 | **Simple version of `srcrec_dstrec`:** a three-frame button sheet picking normal, hover or pressed by mouse state. | KEEP |
| textures_sprite_explosion | 1 | 92 | **Simple version of `srcrec_dstrec`:** a 5×5 explosion sheet on a loop. | KEEP |
| textures_gif_player | 2 | 252 | Decode an animated GIF and play it with per-frame delays, a scrubber, step buttons and a speed slider. | KEEP |
| textures_background_scrolling | 2 | 103 | Three parallax layers scrolling at different speeds, each drawn twice for a seamless loop. | KEEP (flagship) |
| textures_blend_modes | 2 | 95 | A foreground composited over a background through alpha, additive, multiply and premultiplied blends. | KEEP |
| textures_bunnymark | 2 | 130 | Hold to spawn thousands of bouncing bunnies: a draw-call stress test. | KEEP |
| textures_fog_of_war | 2 | 179 | Fog stored as one texel per tile, bilinear-filtered into soft edges as the player moves. | KEEP |
| textures_magnifying_glass | 3 | 163 | A circular 2× magnifier rendered through a zoomed Camera2D, revealing multiply-blended hidden bunnies. | KEEP |
| textures_npatch_drawing | 2 | 142 | Nine-slice panel drawing: corners fixed, edges and centre stretching to the mouse. | KEEP |
| textures_polygon_drawing | 2 | 109 | A texture mapped onto a spinning irregular ten-sided polygon. | KEEP |
| textures_sprite_stacking | 2 | 145 | 122 cross-section slices stacked in world Y to fake a 3D model, under the orbit camera. | KEEP |
| textures_tiled_drawing | 2 | 215 | A sub-rect of a pattern sheet tiled across an area, with scale, rotation and tint sliders. | KEEP |
| textured_curve | 2 | 396 | A road texture swept along a draggable cubic Bezier as a UV-mapped ribbon of quads. | KEEP |
| render_texture | 3 | 122 | An animated scene drawn once into a render texture, then composited as a tinted grid: render once, reuse many. The RTT tutorial cites it. | KEEP — sibling: `recursive_hud` |
| recursive_hud | 3 | 133 | **Sibling of `render_texture`:** a HUD rendered once into a render texture, then composited as a shrinking, dimming tunnel. | KEEP |
| textures_framebuffer_rendering | 3 | 325 | One world drawn into two framebuffers side by side: an observer showing the other camera's frustum, and a magnified viewfinder sampled back out. | KEEP — sibling: `split_screen` |
| split_screen | 3 | 228 | **Sibling of `textures_framebuffer_rendering`:** two players' cameras on one world, each into its own render texture, side by side, each tinted by the fog zone it is in — the local-multiplayer split screen. | KEEP |

### Text

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| text_layout | 2 | 174 | A baked TTF atlas driving a per-letter rainbow heading, a word-wrapped paragraph, several sizes from one atlas, and `measureText` boxes. | KEEP — simple version: `text_font_loading` |
| text_font_loading | 1 | 96 | **Simple version of `text_layout`:** load a TTF and draw a sample at several sizes from one atlas, with its metrics. | KEEP |
| writing_anim | 2 | 73 | A typewriter reveal with a blinking cursor placed by `measureText`. | KEEP |
| text_font_sdf | 3 | 193 | One 16 px font baked as a bitmap and as an SDF, both magnified by a slider: the bitmap blurs, the SDF stays sharp. | KEEP — sibling: `text_font_filters` |
| text_font_filters | 2 | 158 | **Sibling of `text_font_sdf`:** the same magnified-atlas comparison, with point versus bilinear sampling. | KEEP |
| text_unicode_ranges | 2 | 199 | Toggle Unicode ranges to re-bake the atlas at runtime and watch fallback boxes become glyphs. | KEEP — simple version: `text_codepoints_loading` |
| text_codepoints_loading | 2 | 156 | **Simple version of `text_unicode_ranges`:** the codepoint set chosen once at load — the same TTF baked ASCII-only and extended, side by side. | KEEP |
| text_inline_styling | 2 | 328 | `[c…]`, `[b…]` and `[r]` tags inside a string change foreground and background per styled run. | KEEP |
| text_sprite_fonts | 2 | 194 | XNA-style bitmap fonts from a PNG atlas, with live scale and spacing. | KEEP |
| text_strings_management | 2 | 382 | Word chips you drag to join and tap to split into characters: a live split/join playground. | KEEP |
| text_on_texture | 3 | 98 | A 2D sign rendered every frame into a render texture and mapped onto a spinning cube. | KEEP |
| text_field | 3 | 80 | **Simple version of `ui_text_editing`:** a single-line field; on a phone, a hidden DOM `<input>` brings up the soft keyboard. | KEEP |

### 3D basics and meshes

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| models3d | 3 | 98 | Every immediate-mode 3D primitive (sphere, cube, cylinder, capsule, cone) in its wireframe bounding box. | KEEP — simple versions: `cube3d`, `3d_probe` |
| cube3d | 3 | 79 | **Simple version of `models3d`:** one spinning cube, solid and wireframe, over a grid, beside a reference sphere. The tier-a smoke set's 3D example. | KEEP |
| 3d_probe | 3 | 98 | **Simple version of `models3d`:** a few primitives on a lit plane, orbited by dragging (`updateCamera(.orbital)`). | KEEP |
| camera_controls | 2 | 113 | The shared `z.OrbitCamera`: orbit, pan and zoom by mouse and touch, gated on the UI — the reference for 3D input. | KEEP |
| orthographic_projection | 2 | 150 | One scene with the camera toggled between perspective and orthographic projection. | KEEP |
| yaw_pitch_roll | 2 | 218 | Pitch, yaw and roll composed into one matrix and applied to a plane built from primitives. | KEEP |
| tesseract_view | 3 | 136 | A 4D hypercube rotating through the XW plane, projected to 3D. | KEEP |
| textured_cube | 3 | 77 | A checker-textured cube: the smallest textured draw in the immediate 3D pass (`drawCubeTexture`). `text_on_texture` puts live content on the same cube. | KEEP |
| directional_billboard | 2 | 252 | An 8-direction Doom-style sprite billboard picking its atlas frame from the camera's angle, with a walk cycle. | KEEP — simple version: `billboards` |
| billboards | 3 | 166 | **Simple version of `directional_billboard`:** a ring of glowing alpha sprites that always face the camera, among solid cubes. | KEEP |
| skybox | 3 | 82 | A gradient skybox drawn as a fullscreen far-plane pass behind 3D objects. | KEEP |
| models_geometric_shapes | 2 | 183 | Every procedural mesh generator in a 2×4 grid under the orbit camera, with a solid / wire / both toggle. | KEEP — siblings: `shapes_gallery`, `platonic_solids`, `icosphere_demo`; simple version: `wireframe` |
| wireframe | 3 | 106 | **Simple version of `models_geometric_shapes`' wire toggle:** a generated sphere and cubes, solid or wireframe, through the retained `loadModelFromMesh` / `drawModelWires` API. | KEEP |
| shapes_gallery | 2 | 121 | **Sibling of `models_geometric_shapes`:** eight more parametric primitives (Klein bottle, trefoil, hemisphere…) and a dumbbell welded with `meshMerge`. | KEEP |
| platonic_solids | 2 | 94 | **Sibling of `models_geometric_shapes`:** the tetrahedron, octahedron, dodecahedron and icosahedron, flat-shaded and spinning. | KEEP |
| icosphere_demo | 2 | 90 | **Sibling of `models_geometric_shapes`:** an icosphere refining from the icosahedron at subdivision levels 0 to 3. | KEEP |
| mesh_builder | 2 | 146 | Build objects from parts: generate, `meshTranslate`, `meshRotate`, `meshInvert`, `meshMerge`. | KEEP — siblings: `rock_demo`, `dynamic_mesh` |
| rock_demo | 2 | 94 | **Sibling of `mesh_builder`:** procedural rocks from noise-displaced icospheres, one generator with different seeds. | KEEP |
| dynamic_mesh | 3 | 122 | **Sibling of `mesh_builder`:** a quad whose corners breathe each frame through `updateMeshBuffer`. | KEEP |
| instancing | 4 | 139 | 1000 spinning cubes in one `drawMeshInstanced` call. | KEEP |
| waving_cubes | 2 | 164 | A 15×15×15 rainbow cube grid rippling on sine waves: an immediate-batch stress test. | KEEP (flagship) |
| point_rendering | 2 | 383 | A spherical point cloud of rainbow shells as one point-list draw, the count stepping up to 1M. | KEEP |
| heightmap | 2 | 438 | A Perlin image turned into terrain coloured water to snow by height, with a regenerate button. | KEEP |
| first_person_maze | 2 | 608 | Walk a generated maze in first person, sliding along walls by collision-circle checks. | KEEP — sibling: `cubicmap` (the same maze, orbited) |
| cubicmap | 2 | 509 | **Sibling of `first_person_maze`:** the same pixel-map maze mesh, hollow and face-shaded, under an orbit camera. | KEEP |
| first_person_camera | 4 | 134 | **Simple version of `fps_playground`'s camera:** WASD and mouse look across a blocky heightmap terrain; a click locks the pointer, Escape releases it, a drag or a finger looks when unlocked. | KEEP |
| voxel | 2 | 274 | An 8×8×8 block where a tap casts a ray through the crosshair and breaks the nearest voxel. | KEEP |
| box_collisions | 2 | 608 | Drag a player box that turns red when its AABB overlaps an enemy cube or sphere. | KEEP |
| mesh_picking | 3 | 696 | A tap becomes a world ray tested against a quad, a box, a sphere and a live rotating torus mesh. | KEEP |

### Models, skinning and animation

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| obj_bunny | 2 | 91 | The 69k-triangle Stanford bunny from OBJ, with no normals: smooth-normal synthesis and de-indexing. | KEEP — loader siblings: `obj_simple`, `gltf_simple`, `gltf_textured` |
| obj_simple | 2 | 111 | **Loader sibling of `obj_bunny`:** an OBJ cube with quad faces and `v/vt/vn` corners — triangulation and normal indices. | KEEP |
| gltf_simple | 2 | 166 | **Loader sibling of `obj_bunny`:** an embedded binary glTF cube with positions only — flat-normal synthesis and the default material. | KEEP |
| gltf_textured | 2 | 88 | **Loader sibling of `obj_bunny`:** a textured glTF quad — the PNG material path and flat-normal synthesis. | KEEP |
| damaged_helmet | 3 | 129 | The Khronos Damaged Helmet through `z.pbr3d` with all five maps, orbited, pinched and zoomed. In the tier-a smoke set. | KEEP — simple version: `pbr_demo` |
| pbr_demo | 3 | 88 | **Simple version of `damaged_helmet`:** the same helmet through the same `z.pbr3d`, auto-rotating, with no camera input. | KEEP |
| lambert_demo | 2 | 437 | A Lambert-lit textured cube binding vertex uniforms, a sampler and a fragment uniform across three bind groups by hand. `src/zimr.zig` cites it as the canonical hand-wired example. | KEEP — simple version: `cube_demo` |
| cube_demo | 2 | 350 | **Simple version of `lambert_demo`:** a textured spinning cube on one hand-wired UBO — depth texture, vertex layout, MVP, and nothing else. | KEEP |
| bone_socket | 3 | 433 | A real 12-joint glTF rig playing a clip, with a sword socketed to the hand bone by name. | KEEP (flagship) — simple version: `skinned_mesh`; sibling: `models_animation_blend_custom` |
| skinned_mesh | 4 | 517 | **Simple version of `bone_socket`:** a 2-bone waving quad from a tiny GLB embedded in the source, skinned on the CPU, no asset files. `claude.md` cites it for two skinning traps. | KEEP |
| models_animation_blend_custom | 3 | 455 | **Sibling of `bone_socket`:** the same rig blending walk and attack per bone — the upper body attacks, the legs keep walking. | KEEP |
| mocap_viewer | 3 | 512 | Load BVH or FBX captures, play, scrub and compare them in colours. | KEEP |
| geno_dance | 5 | 4286 | BVH and FBX capture driving a skinned character and a MuJoCo robot at once. | KEEP |

### Shader techniques

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| cel_shading | 3 | 688 | A toon-shaded bunny: Lambert snapped to bands, plus an inverted-hull ink outline. | KEEP (flagship) |
| deferred_render | 3 | 899 | An MRT pass fills position, normal and albedo maps, then a fullscreen pass lights four point lights. | KEEP (flagship) |
| fog_rendering | 2 | 533 | A row of tori dissolving into exponential-squared fog, reusing the G-buffer vertex stage. | KEEP (flagship) |
| hybrid_render | 3 | 711 | A raymarched SDF scene and rasterized cubes sharing one depth buffer through fragment-depth writes. | KEEP (flagship) |
| depth_writing | 2 | 498 | A material lies to the depth buffer so cubes pop in front of or sink behind their real positions. | KEEP |
| depth_rendering | 2 | 316 | Each fragment's device depth written into the colour buffer as grey. | KEEP — simple version: `depth_cue` |
| depth_cue | 2 | 122 | **Simple version of `depth_rendering`:** depth shown per object — a grey tint chosen on the CPU from each cube's distance — instead of per pixel. | KEEP |
| decals | 3 | 416 | Click a surface to shader-project a textured decal that wraps around curvature. | KEEP (flagship) |
| shadowmap | 3 | 780 | Two-pass shadow mapping: a directional light shadows a floor, boxes and a bunny. | KEEP — the technique reference; `shadowmap_sw` compares it across targets |
| shaders_lightmap_rendering | 2 | 531 | About thirty lights and their shadows baked into a texture at load and sampled through a second UV set. | KEEP |
| shaders_normalmap_rendering | 2 | 200 | Tangent-space normal mapping on a flat quad under a moving light, with an on/off toggle. | KEEP |
| shaders_vertex_displacement | 3 | 210 | A flat grid displaced into moving swells by sampling a Perlin texture in the vertex shader. | KEEP — simple version: `vertex_texture_test` |
| vertex_texture_test | 2 | 164 | **Simple version of `shaders_vertex_displacement`:** a grid warped by a checkerboard sampled in the vertex stage. `gpu_iface.zig` and `shader_runtime_wgpu.zig` name it the worked example of a vertex-stage sampler. | KEEP |
| shaders_multi_texture | 2 | 360 | One shader mixing two textures by a finger-following mask or a draggable wipe divider. | KEEP |
| shaders_shapes_textures | 2 | 237 | Ordinary shape and texture draws wrapped in a grayscale shader mode switched on and off within one frame. | KEEP |
| shader_effects | 3 | 732 | Colour grade, waves, outline and palette switch over a live 2D scene. | KEEP (flagship) |
| shapes_top_down_lights | 3 | 289 | 2D lights with hard shadow volumes, accumulated per light into a multiplied lightmap. | KEEP |

### Custom pipelines

The `pipeline_*` series is a progression; each step adds one WebGPU mechanism.

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| pipeline_basic | 2 | 124 | The first custom pipeline: a vertex buffer and one draw of a gradient triangle from Zig-authored shaders. | KEEP |
| pipeline_uniforms | 2 | 133 | A vertex-stage uniform buffer holding a per-frame transform; the vertex layout derived from the schema. | KEEP |
| vao_multibuffer | 2 | 173 | One vertex layout split across two buffers, the colour buffer swapped between palettes. | KEEP — the rung before `pipeline_instancing` |
| pipeline_instancing | 2 | 207 | One draw of a grid of triangles fed per-instance offsets and colours from instance-rate buffers. | KEEP |
| pipeline_rendertarget | 2 | 162 | A custom pipeline rendered once into a render texture, then stamped across the screen. | DELETE (Simon, Oct 12) — `pipeline_postprocess` renders into a target, `render_texture` stamps it |
| pipeline_postprocess | 2 | 187 | A triangle rendered into a texture, then sampled by a fullscreen chromatic-aberration and vignette pass. | KEEP |
| pipeline_bloom | 2 | 311 | Full multi-pass bloom: bright pass, separable Gaussian blur, composite, each pass with its own UBO. | KEEP |
| pipeline_msaa | 2 | 207 | The same triangle at 1 and at 4 samples, magnified side by side. | KEEP |
| pipeline_settings | 2 | 153 | The same translucent geometry from two pipelines differing only in blend state: alpha versus additive. | KEEP |
| pipeline_sampler | 2 | 261 | One texture sampled four ways: nearest or linear, repeat, clamp or mirror. | KEEP |
| texture_views | 2 | 328 | A mip chain painted level by level through per-level views, the GPU's choice of level shown in colour, and a texture array drawn layer by layer. | KEEP |
| texture_readback | 3 | 195 | A render texture copied to a buffer, mapped without stalling, and re-uploaded beside the live one. | KEEP |

### One shader on CPU, GPU and comptime; fractals; ray tracing

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| sidebyside | 3 | 298 | One `fn(gl: anytype)` 2D scene drawn by the software rasterizer and by WgpuGl, split by the mouse — the shared draw API rather than a shared shader. | KEEP |
| mandel_sidebyside | 3 | 430 | One Mandelbrot fragment shader on the CPU and on the GPU, panned and zoomed together. | KEEP (flagship) |
| rt_sidebyside | 3 | 400 | One path-tracer shader on the CPU, on the GPU, and baked at comptime in the corner. | KEEP (flagship) — simple versions: `rt_shader`, `cube_sidebyside` |
| helmet_sw | 3 | 703 | One PBR shader on the software rasterizer, on the GPU, and baked at comptime. | KEEP (flagship) |
| shadowmap_sw | 3 | 1400 | One shadow-map shader on the software rasterizer, on the GPU, and baked at comptime. | KEEP (flagship) — simple version: `shadow_sidebyside` |
| four_ways | 3 | 689 | One escape-fractal function run at comptime, on the main thread, on a worker and on the GPU. | KEEP (flagship) |
| cube_sidebyside | 3 | 347 | **Simple version of `rt_sidebyside`:** a ray-traced cube — one ray-box intersector, no noise — on the CPU, the GPU and baked at comptime. | KEEP |
| shadow_sidebyside | 3 | 340 | **Simple version of `shadowmap_sw`:** hard shadows from a second ray instead of a shadow map, on the same three targets. | KEEP |
| decal_sw | 3 | 587 | **Sibling of `helmet_sw` and `shadowmap_sw`:** the decal shader on the software rasterizer and on the GPU. The only user of `z.decal_shaders`. | KEEP |
| mandel_julia | 3 | 90 | A fragment shader morphing continuously between the Mandelbrot and Julia iterations. | KEEP (flagship) |
| julia | 3 | 95 | The Julia set as a fullscreen shader, its constant orbiting. | DELETE (Simon, Oct 12) — `mandel_julia` at t = 1 is the Julia set |
| comptime_mandelbrot | 2 | 138 | The Mandelbrot set evaluated at compile time and baked into the binary. | KEEP — siblings: `comptime_julia`, `julia_gallery` |
| comptime_julia | 3 | 149 | **Sibling of `comptime_mandelbrot`:** the Julia iteration evaluated at compile time. | KEEP |
| julia_gallery | 3 | 160 | **`comptime_julia` with four constants:** four Julia sets evaluated at compile time in a 2×2 grid. | KEEP |
| raytracer | 5 | 847 | A CPU path tracer with a live camera, an ECS-stored scene and ImGui parameters, converging when still. | KEEP — overlaps `rt_workers`, which traces on the worker pool |
| rt_shader | 3 | 143 | **Simple version of `rt_sidebyside`:** its GPU half alone, a path-tracer fragment shader. | KEEP |
| rt_workers | 3 | 940 | A path tracer across the worker pool, tiles landing out of order while a dot keeps spinning. | KEEP |

### Compute, workers and numerics

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| compute_smoke | 1 | 163 | The GPU compute round trip with `z.Compute`: double an array, read it back, draw it as bars, check it on the CPU. | KEEP — the hello-compute; cited by the GPU compute tutorial and tier-a |
| compute_particles | 3 | 246 | 65,536 particles whose kernel flips between GPU and CPU with the state carried across, rendered zero-copy. | KEEP |
| sort_smoke | 2 | 880 | The fluid's counting-sort kernels over 64 hand-checkable particles on CPU and GPU. | KEEP (hidden) — becomes `compute_probe`, running all three checks: the "toolchain or algorithm?" page for a new GPU or backend |
| shared_smoke | 2 | 269 | Pass/fail checks of workgroup shared memory and barriers on this device. | MERGE → `sort_smoke` (one probe page) |
| tile_smoke | 2 | 516 | Shared-memory neighbour tiling checked against brute force on this device. | MERGE → `sort_smoke` (one probe page) |
| fluid_sort | 3 | 1664 | A 20,000-particle Clavet fluid on the GPU with a counting-sort neighbour grid over eleven kernels. | KEEP (flagship) — CPU version: `sph_fluid_2d` |
| sph_fluid_2d | 3 | 934 | **CPU version of `fluid_sort`:** the same viscoelastic fluid, about 2000 particles. | KEEP (flagship) |
| worker_png | 2 | 445 | A slow PNG encode on a worker, so the frame never freezes. | KEEP (flagship) |
| zimrnum_field | 2 | 743 | A 64×64 field built from zimrnum tensors, evaluated on CPU and GPU, drawn with their difference. | KEEP (flagship) |
| zimrnum_train | — | 301 | An XOR network trained on GPU and CPU in lockstep, loss curves side by side. | KEEP |

### Audio

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| audio_mixer | — | 183 | The engine's mixer: a held tone, random blips, master volume, and its voices and queue margin on screen. | KEEP |
| audio_keyboard | — | 252 | A seventeen-key keyboard played from the computer keyboard or the pointer through the mixer's instrument. | KEEP |
| audio_amp_envelope | 2 | 242 | ADSR sliders regenerate the tone's PCM, plotted as it will sound. | KEEP — simple version: `audio_basic` |
| audio_basic | 2 | 161 | **Simple version of `audio_amp_envelope`:** three synthesized tones (square, sine, triangle) played on tap. | KEEP |
| audio_stream_synth | 3 | 148 | A theremin: mouse Y drives the pitch of a pushed `AudioStream`. | KEEP |
| audio_sound_lab | 2 | 344 | A WAV loaded, then polyphony through aliases and stereo positioning in three modes. | KEEP |
| audio_spectrum_visualizer | 2 | 222 | A live FFT of the master bus through an analyser tap. | KEEP |
| composer_drum | 3 | 208 | An 8-step kick, snare and hat loop baked by `composer.Sequence`, with a playhead. | KEEP |
| music_streaming | 3 | 157 | Stream an OGG: play, pause, seek, volume. | KEEP |
| audio_scale_star | — | 1104 | The notes and chords of the major scale drawn around a circle in thirds, so that every chord is three neighbours: its root, its third and its fifth. | KEEP |
| audio_scale_star_hands | — | 7385 | A scale played with two hands - the left chooses a chord, the right plays its notes - and shown several ways at once, each degree of the scale in its own colour in every key. | KEEP |

### Networking

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| net_cursors | 2 | 383 | Everyone in a room sees everyone's cursor and click ripples over WebRTC, through `z.net.Session`. | KEEP — the layers under it: `net_ws_smoke`, `net_rtc_smoke` |
| net_ws_smoke | 1 | 196 | **The signaling layer under `net_cursors`:** the protocol live (WELCOME, JOINED, LEFT, FROM) over `z.ws`. `tools/render_server.zig` serves it as the server's test page. | KEEP |
| net_rtc_smoke | 1 | 361 | **The WebRTC layer under `net_cursors`:** two tabs opening one data channel by hand. | KEEP (hidden) — the middle layer of the network diagnostics |

### Physics engines

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| zimrphysics_demo | 3 | 3231 | Six Jolt-style 3D scenes (pyramid, stack, restitution, friction, funnel…), orbit, launch bodies. | KEEP (flagship) |
| zimrphysics2d_demo | 2 | 6368 | A Box2D-style testbed for the 2D engine, with scene switching and debug-draw layers. | KEEP (flagship) |
| physics_sidebyside | 2 | 300 | The 2D and the 3D engine running the same box drop with nearly identical code. | KEEP |
| fps_playground | 2 | 786 | A capsule character controller walking, jumping and shoving a pile of physics cubes. | KEEP (flagship) — simple version of its camera: `first_person_camera` |
| friction_slope | 3 | 407 | A block on an adjustable incline, checked against Coulomb's tan θ < μ. | KEEP |

### Robotics and control

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| robot_demo | 2 | 849 | A scene table for the articulated-body engine, drawn in 2D: build, step, draw. | KEEP |
| robot_sidebyside | 3 | 484 | One double pendulum as two constrained bodies and as two generalized coordinates; the joint drift readout. | KEEP — simple version: `robot_pendulum` |
| robot_pendulum | 3 | 295 | **Simple version of `robot_sidebyside`'s generalized half:** a double pendulum in generalized coordinates, with an energy-drift readout and an integrator switch. | KEEP |
| robot_contact | 3 | 475 | An arm in reduced coordinates hitting a crate in zimrphysics through kinematic proxies. | KEEP |
| robot_3d | 3 | 2109 | A KUKA iiwa imported from URDF at build time, joint names as an enum. | KEEP |
| ragdoll_compare | — | 533 | MuJoCo's humanoid dropped limp in reduced and in maximal coordinates, timed side by side. | KEEP |
| humanoid | 4 | 1708 | MuJoCo's 27-DOF humanoid from MJCF standing on ankle torque, with live gain knobs. | KEEP |
| quadruped | 4 | 1983 | A Unitree Go1 from MJCF standing under its own controller. | KEEP (flagship) |
| three_leg | 3 | 738 | The Go1 shifting its torso to stand on three legs and reach with the fourth. | KEEP |
| mpc_quadruped | 4 | 481 | A single-rigid-body trunk MPC on the Go1. Its header says nothing holds yet: the loop diverges in a second or two. | KEEP — the active research front, shown with its honest status |
| balance_flywheel | 3 | 353 | Two inverted pendulums pushed alike; the one allowed to spin its arms uses them as a momentum sink. | KEEP |
| catch | 3 | 697 | IK plus PD swats a thrown ball; a planner matches its speed and catches it. | KEEP |
| chain_ik | 4 | 307 | A ten-link chain on a two-number task: the null space, and damped least squares near singularities. | KEEP |
| crane | 3 | 335 | Carrying a swinging load: PD versus a planner that reverses briefly to arrive still. | KEEP |
| gripper | 3 | 481 | A 4-DOF arm with a coupled gripper: an equality constraint closing the loop, IK, gains in frequency units. | KEEP |
| rocket | 4 | 420 | Landing an engine that cannot throttle below 40%: PD versus a planner that leans to waste thrust. | KEEP |
| tracking | 4 | 614 | PD lags a moving target; a planner shown the path 0.3 s ahead does not. | KEEP |
| mpc_cartpole | 5 | 538 | iLQR swinging a weak cartpole up and balancing it, the plan drawn as a ghost, replanned every frame. | KEEP (flagship) |
| cartpole | 4 | 526 | A four-weight linear policy learning to balance by the cross-entropy method, live. | KEEP — the smallest learning example |

### Learning and motion tracking

None of these are in the gallery. The Geno pages are their humanoid counterparts on a different robot.

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| cartpole_duel | — | 1275 | One cartpole held by MPC in front, while PPO, SAC or SuperTrack learn to hold the same one behind it. | KEEP |
| rl_humanoid | — | 357 | PPO learning humanoid locomotion on the CPU, the rollout drawn as it is collected. | KEEP |
| geno_track | — | 617 | Geno pulled through a copied capture by the tracking servo alone, falls counted. | KEEP — the same page on the flex humanoid: `dance_track` |
| dance_track | — | 1472 | **`geno_track` on the flex humanoid:** servo-only tracking of a dance clip — stage 0, no learning. | KEEP |
| getup_train | — | 592 | A policy learning on this device to keep a humanoid with a get-up or dance capture; mean time to failure. | KEEP — the same page on Geno: `geno_ppo` |
| geno_ppo | — | 608 | **`getup_train` on Geno.** | KEEP |
| track_train | — | 481 | SuperTrack learned on this device: CPU stepping, world model and policy trained on the GPU. | KEEP — the same page on Geno: `geno_train` |
| geno_train | — | 516 | **`track_train` on Geno.** | KEEP |
| getup_frames | — | 444 | The get-up reference posed frame by frame, with foot heights and sole flatness. | KEEP (tool) |
| geno_fit | — | 581 | Geno's fitted collision shapes riding the captures, optionally with the skinned mesh. | KEEP (tool) |
| geno_lab | — | 1171 | The training lab: a run folder's parameters and newest weights loaded into a network, and Geno shown following the dance with them, the reference beside him; the weights reloaded while the trainer runs. | KEEP (tool) |

### UI

#### Starters, smoke tests and tours

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| ui_demo | 3 | 81 | One ImGui window with a label, a slider, a checkbox and a counting button. | KEEP — the UI starter; simple version: `ui_smoke_button` |
| ui_smoke_button | 3 | 62 | **Simple version of `ui_demo`:** one window, one line of text, one button. | KEEP |
| ui_minimal_button | 3 | 105 | Three windows through one UiHost, each with a button and a tap counter, tiled to the canvas: the smallest multi-window UI. | KEEP |
| ui_minimal_one_context | 3 | 91 | The same three windows as `ui_minimal_button`, at fixed positions. | DELETE — identical to `ui_minimal_button`, with an older layout |
| ui_log_skeleton | 3 | 165 | `ui_log_viewer`'s structure with four lines of content: "bisection step 3" of a font-bug hunt. | DELETE — a debugging step whose job is done; `ui_log_viewer` is the example |
| ui_mini_plot_smoke | 2 | 107 | One `u.miniPlot` line plot. | DELETE — its header says to delete it once the real plot API landed, and it has (`ui_plot`, `plot_demo`) |
| ui_full_showcase | 5 | 943 | A tabbed tour of every widget, table feature, plot, DrawList primitive, drag-and-drop pattern and polish helper. | KEEP (flagship) — focused versions of its tabs: `ui_widgets_data_types`, `ui_plotting_basic`, `ui_custom_rendering`, `ui_polish`; phone version: `imgui_phone_demo` |
| imgui_phone_demo | 3 | 304 | **Phone version of `ui_full_showcase`:** a five-tab widget tour laid out for a portrait phone, with touch-sized targets. | KEEP |
| ui_widgets_data_types | 4 | 160 | **Focused version of `ui_full_showcase`'s Widgets tab:** slider, drag and input over scalars and `*[2/3/4]T` arrays. | KEEP |
| ui_plotting_basic | 4 | 172 | **Focused version of `ui_full_showcase`'s Plots tab:** `plotLines` and `plotHistogram` sparklines and the `beginTooltip` block. | KEEP |
| ui_custom_rendering | 4 | 378 | **Focused version of `ui_full_showcase`'s Drawing tab:** every DrawList primitive driven by sliders. | KEEP — sibling: `ui_primitives_zoo_phone` |
| ui_primitives_zoo_phone | 3 | 497 | **Sibling of `ui_custom_rendering`:** one card per canvas primitive, each captioned with what it should look like — a check by eye. | KEEP |
| ui_polish | 3 | 148 | **Focused version of `ui_full_showcase`'s Polish tab:** `pushStyle`/`popStyle`, cursor position helpers, `labelText`, `textDisabled`. | KEEP |
| ui_imgui_extras | 3 | 134 | `inputTextWithHint`, `sliderAngle`, item tooltips, `calcTextSize`, `setKeyboardFocusHere`. | KEEP |

#### Text input

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| ui_text_editing | 3 | 200 | Text fields edited as in an editor: selection, word moves, clipboard, undo, scrolling, filters, multi-line, IME. | KEEP — simple versions: `text_field`, `ui_code_editor` |
| ui_code_editor | 4 | 193 | **Simple version of `ui_text_editing`'s multi-line field:** `inputTextMultiline` with a line-number gutter and `pushFont`. | KEEP |
| ui_input_callbacks | 4 | 246 | Input callbacks: a character filter, a password mask, Tab completion, Up/Down history. | KEEP — sibling: `ui_input_flags_zoo_phone` |
| ui_input_flags_zoo_phone | 3 | 369 | **Sibling of `ui_input_callbacks`:** one card per InputText flag, each with a live readout of what it did. | KEEP |
| ui_notes_phone | 4 | 184 | A complete phone app: an autosaving notes pad, from a textarea, the edit callback and saved state. | KEEP |

#### Tables, drag and drop, lists

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| ui_tables_demo | 5 | 350 | A CI build dashboard using every table feature: layout, sorting, scrolling, alternating and per-row tints. | KEEP — simple versions: `ui_tables_basic`, `ui_tables_scroll`; siblings: `ui_kanban_board`, `ui_data_grid_phone` |
| ui_tables_basic | 4 | 134 | **Simple version of `ui_tables_demo`:** a four-column sortable scoreboard. | KEEP |
| ui_tables_scroll | 4 | 165 | **Simple version of `ui_tables_demo`:** 200 rows in a fixed-height table with a sticky header. | KEEP |
| ui_kanban_board | 4 | 226 | **Sibling of `ui_tables_demo`:** despite the name, a task table showing the sort flags `no_sort`, `no_sort_ascending` and `default_sort`. | KEEP |
| ui_data_grid_phone | 4 | 191 | **Sibling of `ui_tables_demo`:** a grid wider than the screen, scrolled on both axes. | KEEP |
| ui_drag_drop_demo | 5 | 223 | Drag build chips between lanes: source, target, preview, highlight. | KEEP — simple version: `ui_drag_drop_source`; sibling: `ui_drag_drop_flags_tour` |
| ui_drag_drop_source | 3 | 116 | **Simple version of `ui_drag_drop_demo`:** the drag source alone; nothing receives the drop. | KEEP |
| ui_drag_drop_flags_tour | 3 | 230 | **Sibling of `ui_drag_drop_demo`:** disabled scopes, auto-repeat buttons and the drop-target flag variants. | KEEP |
| ui_log_viewer | 4 | 457 | An auto-scrolling log with jump-to-top and bottom and copy-all. | KEEP — sibling: `ui_clipper` |
| ui_clipper | 5 | 197 | **Sibling of `ui_log_viewer`:** a 100,000-row log rendered at O(visible) by the list clipper, toggleable to show the cost. | KEEP |
| ui_multiselect_finder | 3 | 327 | A Finder-style list with click, Ctrl-click and Shift-click selection, and a tap mode for phones. | KEEP |

#### Layout, windows and persistence

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| ui_dock_basic | 3 | 198 | Drag-to-dock with drop zones, restoring the pre-dock position, dock node flags, splitters. | KEEP — simple version: `ui_dock_simple`; sibling: `ui_dock_persistence` |
| ui_dock_simple | 3 | 116 | **Simple version of `ui_dock_basic`:** a full-window dockspace laid out by the builder API. In the tier-a smoke set. | KEEP |
| ui_dock_persistence | 4 | 196 | **Sibling of `ui_dock_basic`:** a dock layout and a counter restored after a page refresh. | KEEP — simple version: `ui_persistence` |
| ui_persistence | 3 | 113 | **Simple version of `ui_dock_persistence`:** one window's position, size and scroll restored after a refresh. | KEEP |
| ui_panes | 3 | 189 | A three-pane workspace from splitters, child windows and tree nodes. | KEEP |
| ui_window_menubar | 4 | 238 | Three windows, each with its own menu bar, and a status bar. | KEEP |
| ui_tabbar_tour | 3 | 161 | Tab bars: closeable tabs, pinning, unsaved markers, forced selection. | KEEP |
| ui_combo_custom | 4 | 153 | Combo dropdowns filled with arbitrary widgets. | KEEP |
| ui_color_picker | 4 | 122 | `colorPicker` in bar and wheel layouts, with and without alpha. | KEEP — in tier-a |
| ui_shortcuts | 4 | 193 | Key chords with `Ui.shortcut`: Ctrl+S, undo and redo, auto-repeat, strict modifiers. | KEEP |
| ui_mouse_drag | 4 | 217 | Cursor zones and a square dragged by consuming the drag delta. | KEEP |
| ui_dev_tools | 3 | 203 | The built-in overlay: metrics, debug log, inspector. | KEEP |

#### Drawing inside the UI, and apps

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| ui_drawlists | 4 | 127 | The background and foreground draw lists: a grid under every window, a watermark above. | KEEP |
| ui_canvas_demo | 3 | 225 | A tiny node editor on the canvas widget, with pan and zoom. | KEEP |
| ui_custom_widget | 3 | 188 | A star-rating widget built on `beginItem`/`endItem` and widget state storage. | KEEP |
| ui_pomodoro_phone | 4 | 227 | A pomodoro timer: an animated progress ring drawn on a canvas, colour tweened toward the end. | KEEP |

### Plotting

| Example | ★ | LOC | What it shows / teaches | Verdict |
| --- | :-: | ---: | --- | --- |
| plot_demo | 3 | 1421 | The ImPlot-style showcase, one tab per feature. | KEEP (flagship) — simple version: `ui_plot` |
| ui_plot | 3 | 128 | **Simple version of `plot_demo`:** one interactive plot — live curves from sliders, drag to pan, wheel to zoom, a Fit button. | KEEP |
| plot3d_demo | 3 | 236 | Three 3D series (a helix, a surface, a scatter) under a drag-orbit. | KEEP (flagship) — sibling: `plot3d_gallery` |
| plot3d_gallery | 3 | 417 | **Sibling of `plot3d_demo`:** ImPlot3D's README plots in tabs. | KEEP |
| native_plot_png | — | 83 | A native program that draws a plot into a supersampled canvas and saves it as a PNG. | KEEP |

## Doing it

Each delete touches more than its directory:

1. `examples/<name>/`.
2. Its row in `wgpu_apps` in `build.zig` (about line 5214), or its bespoke build block.
3. Its card in `src/web/manifest.json`, which drives both the web gallery and `zimr_gallery`.
4. Its mentions elsewhere:
   - `julia`: `src/web/readme.html` names it (`doc_gate` checks the published pages' links). Its shader
     `examples/julia_fs*.zig` stays, because `wgpu_bringup` uses it.
   - `pipeline_rendertarget`: a comment in `src/tests/features_test.zig` (line 101) names it.
   - `ui_minimal_one_context`, `ui_log_skeleton`, `ui_mini_plot_smoke`: nothing outside `build.zig` and
     the manifest.

The probe fold: `shared_smoke`'s and `tile_smoke`'s kernels (`shared_rotate.zig`, `tile_gather.zig`) and
their checks move into `sort_smoke`, renamed `compute_probe`; its build row wires all three kernels, and
`src/compute_host.zig` and the notes that name `sort_smoke` follow the rename.

## Gallery cards

**Rewritten Oct 12.** 291 of the 305 cards in `src/web/manifest.json` now say what a visitor sees and
learns, and lead with the relation where there is one ("simple version of keys: ..."). The gallery's
search box matches descriptions, so a search for `keys` also finds its simple versions. The fourteen
cards left alone were already good (thirteen robotics ones) or written the same day by another session
(`profiler_flamegraph`). The style: ASCII only, lowercase start, no trailing period, 28 to 135
characters, no internal names (phases, plans, file paths).

What the rewrite fixed:

- **Wrong cards.** `tic_tac_toe` claimed "a perfect opponent" (two players share the screen),
  `skinned_mesh` claimed GPU skinning (it skins on the CPU), `ui_kanban_board` read as a kanban board
  (it is a sortable table), `recursive_hud` claimed to showcase `pushRenderTexture`, and
  `balance_flywheel` described a reaction wheel where the demo now spins arms.
- **Placeholders.** About thirty cards were only the title ("starfield", "plot demo", "SPH fluid 2D").
- **Internal jargon.** Ten UI cards named "Phase A2 of the imgui-parity arc" and the like, and
  `pipeline_bloom` and `pipeline_sampler` cited `webgpu_control.md`.
- **Encoding damage.** Seven UI cards carried `â€"` where an em-dash had been mis-encoded.

Still open:

- **Misfiled modules.** Twenty-four `ui_*` examples sit under "core"; `ball_physics` sits under
  "shapes", `bouncing_ball` under "physics", and `langton_ant` under "compute".
- **A source header.** `rt_shader`'s header says it accumulates samples while the camera is still; the
  code only varies a per-frame seed. Its card no longer repeats the claim.
