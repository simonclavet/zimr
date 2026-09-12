> **ACTIVE.** Port plan: **182 DONE / 7 TODO / 28 N/A** of 217. Clusters left:
> text 2, shaders 2, audio 3, models 2 — **textures + core: COMPLETE.**
> (shaders now 2). **shapes + shapes-adjacent: COMPLETE.** Latest: `text_font_sdf` — SDF text
> (crisp at any zoom), which drove `z.loadFontSdf`, the pure/unit-tested `image.coverageToSdf`
> (signed 8SSEDT), and the `src/shaders/text_sdf_fs.zig` smoothstep shader. Simon verifies GPU
> visuals ("this is why I am here"), so shader/GPU-dependent items are back in scope.
> Before that: `input_actions` (closed core), `text_sprite_fonts`, `textures_gif_player`.
> NB: the older per-category table below has known count drift (flagged before); the line above is
> the reconciled tally for the items actually touched.
>
> **LEAK-FREE IS NOW MANDATORY for every new example.** Author each new example `.memory = .managed`
> with a `deinit` that frees ALL its GPU resources, and confirm a FLAT twice-lifecycle census:
> `zig build smoke-test -Dfocus=<snake>` then grep the log for `✗ FAIL`/`LEAK` (NOT just the first
> "PASS" — printPass prints before the gate). Recipe: State-held WgpuTexture/RenderTexture/CpuFramebuffer
> → `.deinit()`; raw pipeline/buffer/bind-group Handles → `wgpu.destroyX` (createRenderPipeline is
> direct/uncached → the pipeline is owned); build-only modules/layouts → destroy inline after the
> pipeline+bind groups are built; shared meshes/textures across N objects → free the unique set ONCE;
> a texture you register-and-forget → `registerOwnedTexture` (engine frees it on resetRegistry).
> CAUTION: a managed PASS means nothing unless the example actually RECOMPILED (watch for a build error).

---

## YOU ARE HERE (last session)

**Just landed: `shaders_normalmap_rendering` (zimr866) — a focused normal-map demo (procedural
egg-carton normal map on a sphere, one orbiting light, tap toggles bump on/off), distinct from
`pbr_demo`. It drove a real engine addition: `z.pbr3d.Renderer.loadMesh` — the PBR renderer builds a
Model from a PROCEDURAL mesh + caller-supplied maps now, not only glTF. own_frame demo (no smoke
census, like pbr_demo): gated by standalone rc=0 + lint + Simon's eyes.

**Prior: `text_font_sdf` — the marquee text item, first GPU/shader port since Simon took
the visual-verification loop ("don't worry about not being able to verify on GPU — this is why I am
here").** SDF text stays crisp at any zoom: a coverage atlas blurs when magnified, an SDF atlas +
`smoothstep(0.5)` shader reconstructs the edge. Drove `image.coverageToSdf` (a PURE, unit-tested signed
8SSEDT — coverage → distance-in-alpha), `z.loadFontSdf` (bake coverage, convert, upload LINEAR), and
`src/shaders/text_sdf_fs.zig` (raylib's sdf.fs as a 2D user shader; SDF glyphs are `gl.text` between
`beginShaderMode`/`endShaderMode`). The example draws one word with a small bitmap font AND the SDF font
at a live size slider — crank it, bitmap dissolves, SDF holds. `.memory = .managed`, FLAT census (the
`Shader2D` pipeline frees in deinit). Headless proof = the coverageToSdf test + shader-compiles + FLAT
smoke; crispness is Simon's screenshot. **Remaining: text 2, shaders 3, audio 3, models 2.**

**Previously: `input_actions`** — an ACTION MAP (logical actions ← two swappable touch schemes), which
CLOSED the core cluster along with `core_window_letterbox` (covered by `viewport_scaling`) and the two
`core_highdpi_*` items (N/A on web).

**Previously: `textures_framebuffer_rendering` — and it was NOT the "quick win" this plan called it.**
The example is honest raylib (two framebuffers, two cameras, a frustum prism, a cropped viewfinder) with
phone controls (per-pane touch-steered `OrbitCamera`s, portrait/landscape split, UI panel). But writing it
exposed THREE real engine bugs, now fixed: the `gl.texture` `.source` units lie (documented pixels, consumed
as UVs — 5 call sites had each hand-rolled the conversion); the 3D **camera UBO** was single-slot, so ANY app
with two `beginMode3D` passes (including the shipped `split_screen`) had every pass silently read the LAST
camera; and the 3D **vertex streams** all restarted at offset 0 per flush, so a second pass — or two
`drawMeshInstanced` calls in one frame — overwrote geometry an earlier recorded draw still referenced.
`split_screen` was RED on the smoke clobber gate before this turn and is green now. **Lesson for this plan:
"near-free, the engine already has the pieces" is a hypothesis, not a status** — the pieces existed but had
never been driven twice in one frame.

**Previously: `shaders_shapes_textures` (the highest-value engine item on the board).**
`z.Shader2D` / `z.beginShaderMode` / `z.endShaderMode` — a user fragment shader over the ORDINARY 2D
batch, not a fullscreen quad. Device-verified. Details in the shaders cluster below.

**Also fixed, found by device screenshot on THAT example:** a `.fit`-mode scissor bug in the UI. The UI
clipped its windows to a rectangle shifted sideways. Root cause: `shapes2d.beginScissorMode` RE-DERIVED
the logical→framebuffer transform and applied only the DPR half, never the `.fit` letterbox
(scale + centring offset). Correct in `.responsive` (where logical IS CSS, so the letterbox is identity),
silently wrong in `.fit` — and `.fit` is exactly what the raylib ports use, so this was latent under
EVERY fixed-design port that draws UI. Measured error on the device geometry: **+184 backing px
horizontally.** Fix: the letterbox now rides on `WindowState` (`fit_scale`/`fit_off_x`/`fit_off_y`),
derived ONCE in `wgpu_app` from `fitScaleOffset` and consumed by the scissor path — the same way
`render_width`/`render_height` already travel. This is the third time this exact bug class has bitten
(`logicalToCss`/`cssToLogical` exist *because* touch, mouse and scissor each grew a private copy of this
transform); the comment on those functions says "don't re-derive the transform" and `shapes2d` was doing
precisely that.

**NEXT, by value ÷ cost (see ATTACK ORDER below):**
1. `textures_framebuffer_rendering` + `textures_to_image` — both probably near-free on the existing
   RTT / readback paths. Bank the quick wins.
2. `core` ×4 — mostly VERIFY-AND-CLOSE (highdpi + letterbox look engine-covered already). Close them
   HONESTLY with a written reason; do not fake ports to make a number go up.
3. `text_strings_management` — cheapest item on the board, no engine work.

**Known limit carried forward from `Shader2D`:** a 2D user shader gets exactly ONE texture (group 1 is
the batch's single `texture0`). A multi-sampler 2D shader needs the batch's bind group reworked. Nothing
on the TODO list needs that yet.

---

# raylib sample port — completion plan

Goal: finish porting raylib's example set to zimr (wgpu_* examples). Every raylib sample is bucketed DONE / TODO / N/A below.

**Status (raylib-master, 217 samples): 171 DONE, 20 TODO (in-scope), 26 N/A.**

> Reconciled T12 against the raylib-master source (uploaded zip) AND the live `examples/` dir.
> DONE = exact/substring name match OR a conceptual rename verified against `examples/` this
> pass (e.g. `mandelbrot_set`→`mandel_julia`, `rotating_cube`→`cube3d`, `loading_gltf`/`model_shader`
> →`helmet_sw`, `3d_camera_*`→`cube3d`/`first_person_camera`, `3d_picking`→`mesh_picking`,
> `game_of_life`→`life`, `{color_correction,texture_outline,palette_switch,texture_waves}`→`shader_effects`,
> `billboard_rendering`→`billboards`, `input_gestures`→`gestures_demo`, `music_stream`→`music_streaming`,
> `input_box`→`text_field`, `{words_alignment,rectangle_bounds,format_text}`→`text_layout`, `3d_drawing`→`text_on_texture`).
> Every TODO item was confirmed ABSENT from `examples/`. ±5 at the margins (some textures/text may be
> partly covered by `image_editor`/`basic`).

| category | total | done | todo | n/a |
|---|---|---|---|---|
| core | 49 | 31 | 0 | 18 |
| shapes | 41 | 40 | 0 | 1 |
| textures | 32 | 30 | 1 | 1 |
| text | 16 | 14 | 2 | 0 |
| models | 30 | 23 | 3 | 4 |
| shaders | 35 | 31 | 3 | 1 |
| audio | 11 | 8 | 3 | 0 |
| others | 3 | 0 | 0 | 3 |
| **all** | **217** | **177** | **12** | **28** |

**WgpuGl 2D transform stack — SYSTEMIC GAP CLOSED (this session).** The wgpu path's immediate-mode `vertex3f` already applied `self.modelview` to every vertex, and `matrixMode`/`loadIdentity`/`multMatrix`/`frustum`/`ortho` existed — but `pushMatrix`/`popMatrix`/`translate`/`rotate`/`scale` did NOT, so any `gl: anytype` code using the rlgl matrix stack simply never compiled against WgpuGl. Added all five to `src/WgpuGl.zig` (a 32-deep modelview save stack + translate/rotate/scale that post-multiply modelview in GL order, via `zm.translation`/`rotationX|Y|Z`/`scaling`). This unblocks the rlgl matrix API on the wgpu backend. NOTE: `drawTexturePro` rotation already worked (it computes rotated vertices directly, no stack), so the stack's unique unblock is `drawTextureNPatch` and rotated text (the `rlTranslatef`/`rlRotatef` wrappers in text2d.zig).
  Instantiating `drawTextureNPatch` against WgpuGl also surfaced a LATENT BUG in the function (never compiled before because never instantiated): it indexed `dest` (a `Rectangle`) as `dest[0]/dest[1]` — fixed to `dest.x/dest.y`. The 9-patch vertex grid is authored in local 0-based coords (`va_x=0` … `vd_x=patch_w`) and the modelview `translate(dest.x,dest.y)` places it, so geometry is correct. `textures_npatch_drawing` was rewritten from its manual `drawTextureRec` 9-slice workaround to call the engine's real `drawTextureNPatch` (register the texture via `z.registerTexture` for id-binding; non-owning, WgpuTexture freed in deinit). Smoke leak-clean, gate green, standalone built for device confirm.
  **The actual blank-render bug was a THIRD, deeper one — `registerTexture` returned 0 before the first frame.** With the matrix stack + geometry both proven correct in-sandbox (a mock-gl harness ran the real `drawTextureNPatch` and dumped 36 verts on-screen with correct UVs; an on-screen `tex_id` + solid-rect diagnostic on device then showed `tex_id = 0` with the rect visible), the fault was isolated to texture registration. `wgpu_app.registerTexture` read `app.renderer_2d` and returned 0 if null — but the 2D renderer is created lazily on the first frame, and examples register textures in `init` (before any frame), where it is null. loadFont worked only because it *ensures* the renderer (inits it if null) before registering. FIX: `registerTexture` now ensures the renderer the same way. This had silently broken EVERY `drawTexturePro`/`drawTextureNPatch` call with a user (non-font) texture — the path was never exercised before, so it was never caught. METHODOLOGY: the mock-gl harness (run the real `gl: anytype` draw fn against a recording mock, in-sandbox) is now a proven tool for validating 2D geometry emission without a device; pairs with the font PNG harness for the CPU-render side.



  SUBSYSTEM MAP for "all samples working well": (1) WgpuGl 2D transform stack — CLOSED (this session). (2) CPU text-into-image — CLOSED (this session). (3) GPU->CPU texture readback (blocks `textures_to_image`) — STILL OPEN.

**CPU text-into-image subsystem — ROOT-CAUSE FIX (this session).** `imageDrawTextWithFont` (bake text onto a CPU image before it becomes a texture) never worked with ANY `z.loadFont` (TTF) font. Three layers, all now fixed and sandbox-verified:
  1. *Root cause* — `bakeFontAtlas` (the TTF path, `text2d.zig`) rasterized glyphs into the shared atlas but set each `glyph.image = zeroes`; only the default-font path carved per-glyph CPU bitmaps. `imageDrawTextWithFont` samples `glyph.image`, so it drew nothing. FIX: carve each glyph's RGBA out of the atlas in the `out_glyphs` loop. `unloadFontData` already frees `glyph.image` via `unloadImage`, so no new teardown surface.
  2. *Quality* — `imageDraw` sampled nearest-neighbor, so the device-DPR atlas (font bakes at logical x DPR ~= 90px on a DPR-3 phone) downsampled to a ~30px logical draw dropped thin strokes. FIX: box-average the source footprint of each dest pixel when downscaling (>1.25x); 1:1 / upscaling stays nearest. Benefits all image downscaling.
  3. *Scale* (kept from earlier) — `imageDrawTextWithFont` scale is `fontSize / base_f` (was clamped to 1.0 when shrinking).
  **METHODOLOGY WIN:** built a host-native harness `src/test_font_render.zig` (lint-excluded via build.zig `deletion_skip`; never compiled into a build) that runs the pure-CPU path bakeFontAtlas -> imageDrawTextWithFont -> exportImageToMemory(PNG) and writes the PNG to stdout, so the render is `view`-able IN-SANDBOX with no device round-trip. Build: `$ZIG build-exe --dep zm --dep roboto -Mroot=src/test_font_render.zig -Mzm=src/zimrmath.zig -Mroboto=assets/RobotoMono-Regular.ttf -femit-bin=/tmp/font_test` then `/tmp/font_test > out.png 2>stats.txt`. Any pure-CPU render path (image ops, rasterizer, codecs) can be debugged this way now; only true GPU-render output still needs device eyes. This unblocks the `text_font_*` cluster.

**Leak-free-standard port (this session):** `textures_npatch_drawing` (device-confirmed, `.memory = .managed`, FLAT). `textures_image_text` was attempted but DEFERRED — CPU text-into-image needs device-in-the-loop work (see textures list). `textures_npatch_drawing` — authored `.memory =
.managed` from the start (panel WgpuTexture freed in deinit; font atlas engine-owned). FLAT census,
device-buildable. ENGINE NOTES this drove: exported `z.Texture` (types.Texture) for the rlgl draw
path; and found `drawTextureNPatch` (image.zig) is BROKEN in the wgpu path — it calls the GL matrix
stack (`gl.pushMatrix/translate/rotate`) which WgpuGl lacks, so it traps at compile. Worked around by
composing the 9-slice directly from `drawTextureRec` (normalized-UV source → scaled dest rect, which
DOES work). TODO(engine): either give WgpuGl a 2D transform stack or rewrite drawTextureNPatch to bake
the transform per-vertex (nPatchQuad already emits via vertex2f) — then drawTextureNPatch works for all
rlgl callers. Same latent trap likely affects any rlgl fn using pushMatrix (drawTexturePro rotation).

**imageDrawTextWithFont scale FIX (this session):** the CPU text-into-image path clamped `scale` to
1.0 when the requested size was smaller than the font's baseSize — but fonts bake at DEVICE pixels
(logical × DPR), so on a DPR-3 phone a size-30 draw used base_f≈90 → scale 1.0 → 90 px glyphs that
overran the small image (text INVISIBLE on device, fine at DPR 1). Changed to `scale = fontSize /
base_f` so imageDraw's nearest-neighbor sampler downsamples the baked glyph. Only textures_image_text
uses imageDrawTextWithFont (just exported), so no regression surface. LESSON: headless smoke can't
catch DPR-dependent render bugs — device-verify anything touching baked-font sizing.

## TODO — genuinely missing, grouped by the engine work each drives (highest-leverage first)

**Progress (latest session):** SPRITE/IMAGE cluster advanced — `textures_background_scrolling`
(3-layer cyberpunk parallax, in the launcher), `textures_sprite_animation` (scarfy 6-frame; forced the
PNG palette-decoder fix in `codecs.zig` — PLTE/tRNS colortype-3 was ignored), `textures_sprite_explosion`
(5×5 auto-looping sheet), `textures_bunnymark` (hold-drag spawns, seeds 500), `textures_sprite_button`
(3-frame hover/press), `textures_mouse_painting` (RTT canvas via loadRenderTexture + accumulate). All
six device-confirmed. New-example recipe proven: colocate PNGs + `@embedFile`, register in build.zig
master list, AppSpec needs `.deinit`.

**Port recipe lessons (this session, texture cluster):**
- **Colours:** raylib's named palette (`raywhite`, `orange`, `red`, `gold`, …) is `zm.Color`,
  NOT `z.colors` (which is the Tailwind palette: `slate_300`, `amber_500`, `sky_500`, `red_500`).
  For a faithful raylib port bind `const Color = zm.Color; const c = Color;` (the `no-qualified-zm`
  lint forces the two-step bind).
- **Input accessors take `f.input`** first: `z.isMouseButtonPressed(f.input, .left)`,
  `z.isKeyPressed(f.input, .right)`.
- **`imageFromChannel` returns a GRAYSCALE image** (1 byte/px). Free every CPU image with
  `z.unloadImage(gpa, img)` (it reads the format for the right size) — never hand-roll a `w*h*4`
  free, which over-reads grayscale and traps. To alpha-mask a channel, promote it first:
  `z.imageFormat(gpa, &img, .uncompressed_r8g8b8a8)` then `z.imageAlphaMask(&img, alpha_gray)`.
- Degrees→radians is `zm.radFromDeg` (bind at file scope).
- **2D frame primitive is `z.clearViewport(f, color)`, NOT `z.beginDrawing`.** The runtime opens the frame's render pass; `clearViewport` just draws a full-screen clear rect INTO it. `beginDrawing` is only for the 3D-frame path. Examples still call `z.endDrawing(f.gl)` at the end. **Engine hardened (this session):** `App.beginDrawing` now reuses an already-open pass instead of opening a second one (`if (child_tick_active or drawing_active)` → no-op), so a stray `beginDrawing` in a 2D example is harmless rather than a black screen — the double-`beginRenderPass` bug is now structurally impossible. Verified: a redundant `beginDrawing` produces identical smoke telemetry to none (1 begin-pass/frame, same GPU-handle counts); `test` green; box_collisions (3D + beginDrawing) still smoke-passes.
- **Set `.scale_mode = .fit` in the window config for fixed-design raylib ports — the default is `.responsive`.** In `.responsive` the coordinate space is the ACTUAL device size (a phone is ~412 CSS px wide, not 800), so hardcoded 800×450 coords and `screen_w`/`screen_h`-based clamps are wrong on device. For scissor_test this let the mouse-driven box walk off the real screen → the scissor-containment assert at `wgpu_app.zig:3475` (a scissor rect must fit the render area or WebGPU rejects the whole command buffer). `.fit` makes 800×450 a letterboxed design space so hardcoded coords + `getMousePosition` (input inverts the same fit transform) all share it — exactly what shapes_demo does. Alternative: stay responsive and size everything off `f.window.widthf()/heightf()` (the actual logical size).

**Earlier (T12):** `shaders_texture_tiling` + `shaders_eratosthenes_sieve` DONE (as `effect_tiling_fs`
+ a prime-sieve slot in the `examples/shader_effects` gallery).

Strategy (Simon): tackle engine-EXTENDING clusters first — a hard port forces a subsystem into
existence, then the lighter examples that need it fall out cheaply.


## ATTACK ORDER (recommended, by value ÷ cost)

1. ~~`shaders_shapes_textures`~~ — **DONE.** `z.Shader2D` / `beginShaderMode` shipped; see the
   shaders cluster. It was far cheaper than feared: `setBlend` was already the seam.
2. **`textures_framebuffer_rendering` + `textures_to_image`** — both probably near-free on
   existing RTT/readback. Bank the quick wins.
3. **`core` ×4** — mostly VERIFY-AND-CLOSE. highdpi and letterbox look engine-covered already
   (`.scale_mode = .responsive` / `.fit`). Close them HONESTLY with a written reason; do not
   fake ports to make a number go up.
4. **`text_strings_management`** — cheapest item on the board (std.mem + std.fmt, no engine work).
5. **`models_geometric_shapes`** — mesh generators (cube/sphere/cylinder/torus). Useful far beyond
   this one sample; every 3D example currently hand-rolls geometry.
6. **`models_bone_socket` + `models_animation_blend_custom`** — do together, same bone-transform access.
7. ✅ **`text_font_spritefont` + `text_sprite_fonts`** — DONE (merged; `z.loadFontFromImage` + `z.measureTextEx`).
8. **`shaders_vertex_displacement`** — vertex-stage sampler visibility.
9. **`shaders_normalmap_rendering`**, **`shaders_lightmap_rendering`** — need tangents / a 2nd uv set.
10. ✅ **`text_font_sdf`** — DONE (`z.loadFontSdf` + `image.coverageToSdf` + `src/shaders/text_sdf_fs.zig`).
11. **`audio_stream_effects` + `audio_mixed_processor`** — merge; needs an AudioWorklet. Hard.
12. **`audio_module_playing`**, **`text_unicode_emojis`** — decide N/A explicitly, with the reason.

## ENGINE CAPABILITIES LANDED THIS SESSION (context for a fresh session)

- **`z.Shader2D` — raylib's `BeginShaderMode` over the 2D batch** (`src/shader2d.zig`,
  `src/shaders/shapes_filter_fs{,_io}.zig`). A user FS becomes the fragment stage of the shapes
  pipeline. `setBlend` was already the exact seam (flush batch → swap `shapes_pipeline`), so
  `setUserShader`/`clearUserShader` are the same move with a user pipeline. Layout-compatible BY
  CONSTRUCTION: same VS, same VBL, projection at group 0 and texture at group 1 are the RENDERER'S OWN
  bind-group-layout handles (WebGPU only keeps groups bound across a pipeline swap when the layouts
  share a BGL prefix — passing the same handles is the only way to guarantee it). The user `Ubo` lands
  at group 2 for free: that is already what the group convention does with a fragment uniform, and the
  shapes layout leaves 2 empty. `endShaderMode` restores the ACTIVE BLEND, not blindly `.alpha`
  (new `Renderer2D.active_blend`). Extracted `shapesVertexBufferLayout()` + `Renderer2D.pipelineState()`
  as shared defs — a second copy of the VBL or depth state does not ERROR when it drifts, it reads the
  wrong bytes as vertices / gets the whole command buffer rejected.

- **`.fit` letterbox now reaches the scissor path** (`WindowState.fit_scale/fit_off_x/fit_off_y`).
  logical → framebuffer is TWO transforms: the `.fit` letterbox (logical→CSS) and then DPR
  (CSS→framebuffer). `shapes2d.beginScissorMode` only ever did the second, so every UI clip rect under
  `.fit` was shifted by the letterbox offset. Derived once in `wgpu_app` (`fitScaleOffset`) and pushed
  onto `WindowState` alongside `render_width`/`render_height`. **RULE: nothing may re-derive this
  transform** — `logicalToCss`/`cssToLogical` are the one bridge, and their own doc comment says so.

- **WebAudio host bridge** (`ZimrAudio` in `src/bridge.zig`) — the `audio` wasm import namespace did
  NOT EXIST, so *every* audio example died at `WebAssembly.instantiate`. 20 `js_audio_*` host fns
  ported from the old TypeScript host. **Audio worked for the first time ever.**
- **`webtests/verify_imports.js`** — NEW GATE. Runs a standalone's REAL host JS under Node, intercepts
  `WebAssembly.instantiate`, and asserts every namespace the wasm imports is actually provided.
  Requirements are DERIVED FROM THE WASM (`WebAssembly.Module.imports`), so it cannot go stale.
  **Smoke CANNOT catch this class — it auto-stubs unknown imports.** Run it for anything touching a
  new host namespace: `node webtests/verify_imports.js zig-out/standalone/<app>.html`
- **GPU attachment validation in `webtests/runner.mjs`** — implements WebGPU's own pipeline/pass
  compatibility rule with pure bookkeeping (no GPU). Caught a real device-only bug in-sandbox.
  Emits `!ASSERT gpu-validation: ...`, which the existing channel turns into `✗ FAIL`.
- **`src/effects2d.zig`** — the 2D fragment-effect runner, raylib-shaped
  (`beginShaderMode` / `drawFullscreen` / `endShaderMode`). `HostOptions{ .textures = N }` binds N
  source textures (texture at `@group(1)` binding 2i, sampler at 2i+1).
  **`Host.init` takes `gl`, not a bare device** — it reads `depth_format` from the app, because a
  pipeline built with depth cannot bind into a depth-less pass.
- **`z.analyser`** (attach/read/detach) — WebAudio AnalyserNode; FFT written STRAIGHT into wasm memory.
- **New effect shaders:** `effect_ascii_fs`, `effect_mask_fs` (3 samplers), `effect_cubes_fs`.
- **`build.zig` disk guard** — now fails at **≥90% DISK FULL** (one O(1) `statfs`), not at a
  `.zig-cache` size threshold. The old proxy fired on healthy disks and its remedy
  (`rm -rf .zig-cache`) cost a ~16-min cold rebuild.
- **zimrmath vocabulary** — `step` is now CANONICAL (was `stepEdge`); `clamp01` is vector-generic;
  `saturate` / `mix` / `stepEdge` exist ONLY as `@compileError` whose text names the canonical
  spelling. Pinned by `@hasDecl` in features_test.zig.

### text — 2 missing
_FONT SUBSYSTEM — the real gap: SDF fonts, spritefont/bitmap fonts, codepoint & unicode ranges, glyph filters, inline styling, string utils. (Word-wrap bounds / input box / 3D text already covered by text_layout/text_field/text_on_texture.)_

- [x] `text_codepoints_loading` — DONE as `text_codepoints_loading`. **ENGINE WORK this drove:** `z.loadFont` hardcoded ASCII 32..126, but the atlas baker (`bakeFontAtlas(..., codepoints, ...)`) always took an arbitrary codepoint slice — so I factored `loadFont` to delegate to a new **`z.loadFontEx(f, gpa, ttf, size, codepoints)`** (raylib's LoadFontEx). Unblocks accented Latin / Greek / Cyrillic / any non-ASCII script; also the basis for text_unicode_ranges. Non-breaking (loadFont unchanged; text_font_loading + input_mouse regression-smoked). The example loads the SAME ttf twice (ASCII-only vs extended) and draws the same multilingual lines with both, so the difference is visible rather than asserted. **NOTE: probe the TTF's cmap before writing a Unicode example** — the bundled RobotoMono covers ASCII/Latin-1/Latin-Ext-A/most Greek/nearly all Cyrillic but has NO arrows, box-drawing or CJK (those would bake as empty .notdef boxes).
- [x] `text_font_filters` — DONE as `text_font_filters`. **ENGINE WORK this drove:** a texture's sampler filter was FIXED AT CREATION; added **`z.setTextureFilter(gl, texture_id, .point|.bilinear)`** (raylib SetTextureFilter) = `Renderer2D.setTextureFilterById`, which creates a new sampler, REBUILDS that texture's material bind group (the sampler is baked into it), destroys the old pair, and resets the batch's staged-material dedup. App-level wrapper flushes the pending batch first when a pass is open — staged geometry can still reference the old bind group, and destroying a handle the command buffer is about to use is an invalid submit. (raylib's TRILINEAR needs mipmaps the 2D atlas path doesn't generate, so it's not offered rather than faked.) Example: font baked at 20px, drawn up to 120px, SPACE toggles the live filter, UP/DOWN scales. Verified by probe (see lesson below): swap runs every frame with handle counts balanced (sampler/bind_group net flat, post-deinit residual stable) = no leak.
- [x] `text_font_loading` — DONE as `text_font_loading` (embedded TTF via `loadFont`; one baked atlas drawn at 4 sizes; shows `font.baseSize` + `font.glyphCount`). Note: `z.Font` mirrors raylib's C struct — `glyphs`/`recs` are `[*c]` pointers, use `glyphCount` for the count. clearViewport + `.fit`; smoke-clean.
- [x] `text_font_sdf` — **DONE.** The marquee text item, and the first turn where GPU-visual verification was explicitly Simon's job (his call: "don't worry about not being able to verify on GPU — this is why I am here"), which unblocked shader work. SDF text: a coverage atlas blurs when magnified past its bake resolution (bilinear over coverage); a signed-distance atlas + a `smoothstep(0.5)` shader reconstructs a crisp ~1px edge at ANY zoom. **ENGINE WORK this drove:** (1) **`image.coverageToSdf`** — a PURE signed 8SSEDT (8-point sequential Euclidean distance transform) that turns a coverage atlas into distance-in-alpha (0.5 = edge), unit-tested headless (a filled square → monotone field, edge ~0.5, interior > 0.5, far-outside darkest). (2) **`z.loadFontSdf`** — bakes the coverage atlas (reusing `bakeFontAtlas`), runs `coverageToSdf`, uploads LINEAR-filtered (bilinear interpolation of the distance is what smooths the edge). (3) **`src/shaders/text_sdf_fs.zig`** — raylib's `sdf.fs` in the shadermath DSL, a 2D user shader (`beginShaderMode`) that samples `texture0.a` and `smoothstep`s it; SDF glyphs are just `gl.text` drawn between begin/endShaderMode. The example draws the SAME word with a small coverage font AND the SDF font at one live size slider — crank it and the bitmap dissolves while the SDF holds its edge; a second slider drives the shader's edge softness. `.memory = .managed`; smoke ✓ PASS FLAT census (the `Shader2D` pipeline is freed in deinit — `render_pipeline` flat across both lifecycles); standalone 2.03 MB. VALIDATION headless = the `coverageToSdf` unit test + shader-compiles + FLAT smoke; the "is it actually crisp" verdict is Simon's device screenshot. **[zimr864 fix]** first device shot showed mottled/blocky SDF — root-caused by DUMPING the field via a native probe: `spread = sdf_size/8` (8px) crushed the alpha into [0.22, 0.55] (interior never solid). Spread must track stroke half-width, not atlas height — refit to `max(3, sdf_size/18)` (≈3–4px), field now spans ~[0, 0.78], renders solid+crisp. Still a coverage-derived SDF (v1); true outline distance or a 2× supersample-then-downsample is the quality upgrade.
- [x] `text_font_spritefont` — **DONE (covered by the merged `text_sprite_fonts` example below).** Both raylib samples are the same feature (`LoadFont(".png")` → `LoadFontFromImage`); porting them separately would duplicate. The merged example loads raylib's own `custom_mecha` / `custom_alagard` / `custom_jupiter_crash` bitmap fonts — exactly this sample's three fonts.
- [x] `text_inline_styling` — DONE as `text_inline_styling`. Rich text carrying its own formatting: `[cRRGGBBAA]` fg, `[bRRGGBBAA]` bg, `[r]` reset; tag colors are multiplied by the BASE alpha (so fading the string fades its spans). One `walkStyled(emit: bool)` drives BOTH drawing and measuring, so `measureStyled` can never disagree with what was drawn — the example proves it by underlining the last line at its measured width. Each run's width comes from `z.measureText`, which is also what sizes the background rect flush to the glyphs (the same lesson as the undo_redo caret: MEASURE, never assume a monospace advance). Malformed tags degrade to literal text rather than a wrong color. No engine work needed. UI: Randomize button + base-alpha slider.
- [x] `text_sprite_fonts` — **DONE (merges both raylib spritefont samples).** raylib just `LoadFont(".png")`s a few XNA-style bitmap fonts and draws one frozen sentence each; this loads three (mecha/alagard/jupiter_crash, magenta-keyed) and makes them interactive: pick the sample text, scale every font live, and drag inter-glyph spacing (raylib's `DrawTextEx` spacing). **ENGINE WORK this drove — `z.loadFontFromImage`** (raylib `LoadFontFromImage`): the pixel-scan is a pure, **unit-tested** `image.segmentSpriteFont` (first non-key pixel → shared char/line-spacing border; first glyph column → char height; then each line band is walked splitting glyphs on key columns), then the key colour is turned transparent and the cleaned image uploaded as a NEAREST atlas. Glyphs carry `advanceX = 0`, so the existing text path advances by the rec width — exactly raylib. Also added **`z.measureTextEx`** (raylib `MeasureTextEx`, spacing-aware) to centre the adjustable strings. **VALIDATION (headless, no device):** `image.segmentSpriteFont` was diffed against a reference scan and is IDENTICAL on all three real fonts — mecha (charSpacing 8, lineSpacing 8, charHeight 38, **96** glyphs, first rec (8,8,18,38), last value 127), alagard (**95**, last 126), jupiter_crash (**96**, last 127) — plus two in-file unit tests (a synthetic 2-glyph grid exercising the border/height/split branches, and an all-key NoGlyphs guard). `.memory = .managed`; smoke ✓ PASS with a FLAT twice-lifecycle census (`all balanced`), the three atlases engine-owned via `registerOwnedTexture`, the glyph/rec arrays freed by `unloadFont`. verify_imports PASS; standalone 2.19 MB.
- [x] `text_strings_management` — **DONE.** Reimagined as a draggable "String Playground": tap a chip = split into letters, drag-and-drop one onto another = join. Phone-native touch, live joined-sentence HUD. Pure Zig slices, no engine work.
- [N/A] `text_unicode_emojis` — **N/A (decided).** Needs a COLOUR-glyph emoji font (CBDT/sbix/COLR tables); zimr's rasteriser is monochrome-alpha and neither bundled font has emoji coverage. Would require bundling a large emoji font AND implementing colour-glyph table parsing + a colour text path — a big rasteriser feature for one demo. Not worth it; leaving as N/A. (The related `text_unicode_ranges` IS ported, covering the Unicode-handling substance.)
- [x] `text_unicode_ranges` — DONE as `text_unicode_ranges` (runtime atlas re-baking). Buttons toggle script ranges; each toggle re-bakes the atlas via `loadFontEx`, so fallback marks turn into real glyphs and the glyph count grows. raylib's original pulls Devanagari/Arabic/Hebrew/CJK from a big NotoSans — RobotoMono has none of that, so the MECHANISM is identical but the ranges are the ones this TTF actually covers (Latin-1 / Latin Ext-A / Greek / Cyrillic). **ENGINE WORK this drove:** `z.unloadFont` freed only the CPU glyph arrays — the GPU atlas leaked. Added **`Renderer2D.releaseTextureById`** + **`z.releaseFont(gl, gpa, font)`** (destroys the atlas + its material bind group, recycles the registry slot, flushes the batch first). Kept `z.unloadFont` as the CPU-only teardown helper because `deinit(gpa, s)` has NO `gl` — that signature constraint is exactly why two functions are the honest answer. **Proven by negative control:** re-baking every frame WITHOUT releaseFont -> texture=63 / sampler=63 / bind_group=96 (60 abandoned atlases, and 63 is ONE SHORT of the 64-slot registry cap, past which registerTexture hands back the WHITE texture and all text renders as solid blocks); WITH releaseFont -> texture=3, flat. Exactly one atlas stays alive no matter how long you toggle.

### audio — 3 missing
_AUDIO SFX SUBSYSTEM — discrete sound load/play, multi-instance, 3D positioning, module/xm playback, mixed processor, FFT spectrum._

**HOST BRIDGE LANDED (this session).** The `audio` wasm import namespace did not exist in `bridge.zig` — so EVERY audio example (incl. the ones marked DONE: audio_basic, music_streaming, composer_drum, audio_stream_synth) died at `WebAssembly.instantiate`. Smoke stubbed the imports, so it never showed. Ported the old TypeScript host into `ZimrAudio` (bridge.zig); all 20 `js_audio_*` now provided. Verified end-to-end by `node webtests/verify_imports.js <standalone>.html`, which reproduces the bug pre-fix and passes post-fix.

- [x] `audio_amp_envelope` — DONE. Live ADSR sliders (attack / decay / sustain / release + freq) regenerate the Wave on the CPU each change. **No engine work needed — `composer.Envelope` ALREADY carried the full ADSR** (attack_ms / decay_ms / sustain_level / release_ms) and `tone()` multiplies it into every sample; the example just exposes it. The plot is the peak |sample| per column **MEASURED OFF THE GENERATED PCM**, not re-derived from the slider values — so what you see is literally what you hear, and a mis-applied envelope would show. **Pinned with a host test** (`features_test.zig`): tone generation is pure CPU, so the ADSR shape is checkable without a device or ears — peak |sample| in short windows recovers the envelope (at 440 Hz a 20 ms window holds ~9 periods, so its max IS the envelope there); asserts rise-from-silence, full peak, ~0.5 sustain, decay-to-silence, and correct ordering. Negative-controlled.
- [ ] `audio_mixed_processor` — Same machinery as `audio_stream_effects` (raylib's `AttachAudioMixedProcessor` taps the FINAL mix instead of one stream). Merge them.
- [N/A] `audio_module_playing` — **N/A (decided).** MOD/XM tracker playback needs a full tracker decoder in Zig (pattern data, per-channel samples, effect columns) — raylib leans on jar_mod/jar_xm. Very high cost for a single demo, near-zero reuse for the rest of the engine, and nothing else needs a tracker format. Not worth it; leaving as N/A.
- [x] `audio_sound_loading` — DONE, **MERGED** into `audio_sound_lab`. Decodes a real FILE (.wav) and shows what the DECODER found (rate / channels / frames / duration) — the file dictates those, not the caller, which is the whole point of the loading path. **Deliberately a 22KB WAV, not the bundled 96s Vorbis:** decoding that to PCM allocates ~16MB up front and stalls startup — and OGG is already covered, as STREAMING (the right way to play it), by music_streaming. **Wired a new `test_sine_wav` asset module in build.zig** (mirroring `sample_ogg`) so any audio example can reach a short WAV. Pinned with a host test (`features_test.zig`): the decoder is pure CPU, and `waves.loadFromMemory` returns an EMPTY wave on failure rather than erroring (raylib's contract), so a broken asset would otherwise ship as a UI reading 'decode FAILED' and cost a device round-trip. Negative-control checked.
- [x] `audio_sound_multi` — DONE, merged into `audio_sound_lab`. Polyphony via `sounds.loadAlias`: one Sound = one playback slot, so re-playing restarts it; an alias shares the decoded buffer but adds an independent voice, so N aliases = N overlapping copies for the price of one buffer. Round-robin across 8. **A bar per voice lights while it's sounding**, so 'did they actually overlap?' is visible rather than a matter of trusting your ears. LIFECYCLE TRAP: aliases share the source's buffer id — **unload aliases BEFORE the source** or the id is already stale.
- [x] `audio_sound_positioning` — DONE, merged into `audio_sound_lab`. Drag an emitter; pan + distance attenuation are derived from its offset to the listener, and the listener/emitter/connecting line are drawn so the numbers are checkable by eye. **zimr's pan is [-1, 1] (left..centre..right), NOT raylib's [0, 1]** — see `sounds.setPan`.
- [x] `audio_spectrum_visualizer` — DONE. Live FFT via a WebAudio **AnalyserNode**. **ENGINE WORK this drove:** three new host fns in the audio bridge (`js_audio_create_analyser` / `js_audio_get_frequency_data` / `js_audio_destroy_analyser`) + `web.audio.createAnalyser/getFrequencyData/destroyAnalyser` + a `z.analyser` namespace (attach / read / detach). The analyser is a **TAP, not an insert**: master already feeds `destination`, so connecting it additionally to the analyser hands the FFT the same signal without altering what you hear. `getByteFrequencyData` fills its typed array IN PLACE, and the array handed to it is a view straight onto the wasm heap — so the spectrum lands in the caller's slice with NO intermediate copy. Bars use a LOG frequency axis (each bar spans a constant frequency RATIO, which is how pitch works; a linear axis crams all musical content into the leftmost few bars) and attack-fast/release-slow smoothing so they don't strobe. **A 0-bin read is surfaced in the UI** rather than drawn as a convincingly-empty graph.
- [ ] `audio_stream_effects` — **ENGINE (bridge): per-buffer DSP.** raylib's `AttachAudioStreamProcessor` runs a callback over the audio buffer. On the web the honest equivalent is an **AudioWorklet** (a ScriptProcessorNode is deprecated and glitches). Needs a worklet module + a wasm↔worklet path. **MERGE with `audio_mixed_processor`** — same machinery, different tap point.

### textures — 0 missing (cluster COMPLETE)
_IMAGE + SPRITE — CPU image ops (channels/rotate/text; kernel/drawing/processing partly via image_editor), sprite sheets/stacking/explosion/animation/button, blend modes, RTT framebuffer/screen buffer, npatch/polygon/tiled draw, bunnymark, gif, fog-of-war, magnifier, mouse painting._

- [x] `textures_framebuffer_rendering` — DONE. **NOT near-free — this one paid for itself.** The port is two render textures (one per pane, sized to the pane in backing px, stacked on a portrait phone and side-by-side in landscape), each with its own `z.OrbitCamera`: drag a pane and you steer THAT pane's camera (the pane is latched on press, so a drag across the divider keeps its camera), and the observer pane draws the subject camera's frustum as a wire prism — raylib's `DrawCameraPrism`, i.e. unproject the four far-plane NDC corners `(±1,±1,1)` through the INVERSE view-projection built with `far = |position - target|` so the prism is sliced exactly where the subject is looking. The viewfinder overlay (a magnified crop of the subject framebuffer) is the sample's real subject: one `gl.texture(dst, rt, .{ .source })`. Writing it surfaced **three engine bugs**, all fixed this turn: (1) `gl.texture`'s `.source` was documented in pixels but consumed as raw UVs, so all 5 call sites hand-divided and none could flip; (2) the 3D camera UBO was written once per `beginMode3D` into ONE buffer at offset 0 — so any app with two 3D passes (split_screen! this!) had every pass read the LAST camera; (3) the 3D vertex streams (solid/line/textured/instanced) all restarted at offset 0 per flush, so a second pass — or merely a second `drawMeshInstanced` in one frame — overwrote geometry an earlier recorded draw still pointed at. Details in claude.md.
- [x] `textures_gif_player` — **DONE.** raylib's original auto-plays scarfy and toggles a fixed frame-delay with LEFT/RIGHT; this is the honest phone translation and goes further: a FRAME SCRUBBER (`u.slider` is generic over `*u32`, so the bound value IS the frame index — drag to seek, which raylib has no way to do), TIMELINE-ACCURATE playback (each frame held for its OWN native delay, not a single vsync-tick counter), play/pause + loop + frame-step buttons, and a dim checkerboard behind the sprite so the GIF's transparency actually reads (raylib draws it on solid RAYWHITE). **ENGINE WORK this drove — a whole new codec: `codecs.gif`** (GIF87a/89a → composited RGBA8 frames + per-frame delays): variable-width LZW (LSB-first, clear/end codes, the KwKwK case), global + local color tables, the graphic-control extension (delay + transparent index), per-frame DISPOSAL (none / restore-bg / restore-prev), interlacing, and application-extension skip (NETSCAPE loop). Exposed as **`z.loadGifAnim` / `z.GifAnim`** (raylib's `LoadImageAnim` shape). Playback uploads the current frame into ONE `CpuFramebuffer` (nearest → crisp). **VALIDATION (headless, no device): the decoder is PIXEL-EXACT vs Pillow** — a native harness decoded raylib's real `scarfy_run.gif` (128×128, 6 frames, 120 ms) and every frame matched PIL byte-for-byte on all displayed pixels (the only differences were the invisible RGB under alpha-0 pixels, i.e. correct transparency-reveal). Plus two in-file unit tests (a Pillow-produced 2×2/2-frame GIF embedded as ground truth — exercises LCT + transparency + disposal + the app-ext skip; and a bad-signature reject). `.memory = .managed`, FLAT twice-lifecycle census (`GPU handles after shutdown: all balanced`), verify_imports 72/72. Standalone built (2.06 MB) for device confirm.
- [x] `textures_image_text` — DONE. Fixed by the CPU-text subsystem work below; verified in-sandbox via the host PNG harness and by smoke, standalone built for device confirm.
- [x] `textures_npatch_drawing` — DONE (procedural panel, manual 9-slice via drawTextureRec; leak-clean)
- [x] `textures_to_image` — **COVERED, not a fresh port (verified this session).** raylib's whole point is
  `LoadImageFromTexture` (GPU→CPU readback); `examples/texture_readback` already does the full
  GPU→CPU→GPU round-trip (`copyTextureToBuffer` → poll-mapped staging → re-upload) and its own header
  says it ports the GL `loadImageFromTexture`. Re-porting would be a near-duplicate — closed honestly
  rather than faked. (If a raylib-shaped `z.loadImageFromTexture` returning a `z.Image` is ever wanted,
  it is a thin wrapper over that readback path, not a new example.)

### shaders — 4 missing
_2D fragment effects on the DSL (simple_mask, texture_tiling/rendering, shapes_textures, multi_sample2d, ascii, eratosthenes) + normalmap (tangent-space) + vertex_displacement (vertex hook) + lightmap (2nd-UV)._

- [x] `shaders_ascii_rendering` — DONE as a NEW MEMBER of the engine's 2D effect family (`src/shaders/effect_ascii_fs.zig` + `_io.zig`), surfaced as an `ascii` mode in the existing `shader_effects` gallery — which reuses all of its pipeline / bind-group / fullscreen-quad / UI plumbing instead of duplicating it. Engine shaders under `src/shaders/` are AUTO-DISCOVERED by build.zig and `wireEngineWgsl` auto-provides the generated `.wgsl`, so no build.zig edit was needed. **Technique:** dice the scene into character CELLS; take ONE sample per cell, at its centre — that single sample IS the quantisation (the whole cell collapses to one brightness, like a terminal). Brightness picks a glyph off a ramp ` . : - + x # block`. **The glyphs are pure FLOAT MATH (discs + bars over cell-local coords), NOT a bitmap font** — a bitmap font needs a second sampler plus u32 bit-twiddling to unpack rows, and neither dynamic bit-shifts nor `@intFromFloat` are exercised anywhere in this shader family, so they are UNPROVEN on the SPIR-V→WGSL path; float primitives are proven, antialias for free, and scale to any cell size. The cell grid is defined in PIXELS, so the shader is told the live canvas resolution — derive it from the UV and characters stretch with the window's aspect.
- [x] `shaders_lightmap_rendering` — DONE (zimr881). uv2 dual-texture pipeline end-to-end: a ground plane carries pos+uv+uv2 (texcoord2 @loc 5), the FS multiplies base(uv) × lightmap(uv2) (procedural checker base + radial light-pool lightmap). **Key fix:** mvp is a VS uniform and the two textures are FS samplers — resources in BOTH stages, which `loadShaderVF` rejects; used `z.shader.loadShader(MergedSchema)` directly (one schema holding Ubo+Samplers, like cube_demo) which also defaults cull to none so the plane isn't back-face culled. Census-balanced.

- [x] `shaders_multi_sample2d` — DONE, merged into `shaders_multi_texture`. Divider branch = a wipe along x between the two sources, feathered by a `softness` uniform (0 = raylib's hard cut). **ENGINE WORK this drove: `effects2d.Host` bound exactly ONE source texture; it now takes `HostOptions{ .textures = N }`** and binds N — texture at `@group(1)` binding 2i, sampler at 2i+1, which is exactly the layout the shader DSL generates for N `Sampler2D` fields. **Verified that layout against the PBR shader's generated WGSL BEFORE writing any of it** (it binds texture0/1/2 at 0,2,4 and samplers at 1,3,5), and confirmed the new shader's WGSL came out identical. Slots declared with `Sampler2D_atSlot(0/1/2)` — NOT borrowed PBR semantics (`.albedo`/`.metalness`/`.normal`), because these are three peer sources and naming them after PBR channels would be a lie. Shader samples ALL sources unconditionally and selects afterwards: sampling inside a branch is non-uniform control flow, the exact class of bug behind the earlier Chrome/Tint uniformity errors. **LEAK FOUND BY SMOKE:** `effects2d`'s deinit was dishonest — creating a pipeline also creates a bind-group layout, a pipeline layout and a shader module, and it freed only the buffer + bind group. Now owns and frees all six handles (Host frees its two layouts + the vertex module). NOTE `shader_effects` has no `.memory = .managed`, so its leak check is SKIPPED — it had been leaking these silently all along; the engine fix cures it too.
- [x] `shaders_normalmap_rendering` — DONE (zimr866). Focused normal-map demo distinct from `pbr_demo` (full glTF helmet): procedural egg-carton normal map on a `genMeshSphere`+`genMeshTangents` sphere, one orbiting light, tap toggles bump on/off. Drove NEW engine cap `z.pbr3d.Renderer.loadMesh(mesh, .{.base_color,.normal,...})` — pbr3d could load ONLY glTF before; now builds a Model from a procedural mesh with caller-supplied maps (refactor: `uploadDefaultMesh`→`uploadMeshMat` taking a material). own_frame demo → validated by standalone+lint+visual (no smoke census, same as pbr_demo).
- [x] `shaders_shapes_textures` — **DONE. ENGINE: the real raylib 2D shader API.** raylib's `BeginShaderMode`/`EndShaderMode` wrap ORDINARY draws and toggle SEVERAL TIMES per frame (default → custom → default → custom). zimr could previously only run a shader over a FULLSCREEN QUAD (`effects2d`), which is a post-process and cannot filter SOME shapes and not others.

  **NEW: `src/shader2d.zig` (`z.Shader2D`, `z.beginShaderMode`, `z.endShaderMode`).** The user's fragment shader BECOMES the fragment stage of the shapes pipeline. **The whole feature turned out to be small, because `setBlend` was already the exact seam** — it flushes the batch and swaps `shapes_pipeline` between 5 prebuilt blend pipelines. `setUserShader`/`clearUserShader` do the same thing with the user's pipeline.

  **WHY THE SWAP IS FREE:** a shader written against the new `shapes_filter_fs_io` is LAYOUT-COMPATIBLE with the engine's own by construction — same vertex stage (`default_shapes_vs`, reused verbatim), same VBL, same varyings, projection still at group 0, texture at group 1. WebGPU keeps bind groups bound across a pipeline change when the layouts share a BGL prefix, and `Shader2D` passes the renderer's OWN handles for groups 0/1, which is the only way to guarantee that. **The user's `Ubo` lands at group 2 for free** — that is already what the engine's group convention does with a FRAGMENT uniform (vertex→0, samplers→1, fragment→2), and the shapes layout leaves group 2 empty. Nothing had to move.

  **THE FLUSH IS LOAD-BEARING.** Both `setUserShader` and `clearUserShader` call `flushBatch` first: geometry already queued was queued to be drawn with the CURRENT pipeline, and swapping without draining would retroactively filter everything drawn earlier in the frame. Smoke telemetry proves it: **`set_pipeline=5`/frame** (initial bind + 4 swaps) and **12 separate `draw_indexed`** — the batch really is split at each boundary.

  `endShaderMode` restores the ACTIVE BLEND MODE, not unconditionally `.alpha` (new `Renderer2D.active_blend`), so a user shader nested inside `beginBlendMode(.additive)` does not silently drop the blend.

  Engine refactors this drove: `shapesVertexBufferLayout()` and `Renderer2D.pipelineState(blend)` extracted as shared definitions — a second copy of the VBL or the depth state does not ERROR when it drifts, it reads the wrong bytes as vertices / gets the command buffer rejected.

  Shader is `src/shaders/shapes_filter_fs.zig` = raylib's `grayscale.fs`, **using raylib's exact Rec.601 luma (0.299/0.587/0.114), not Rec.709** — a port that looked "more correct" than the thing it reproduces would make the side-by-side a lie.

  Example follows raylib's 3-column interleave exactly (circles default / rects custom / triangles default / sprite custom), with raylib's own `fudesumi.png`. **Improvements:** the grey is a SLIDER not a toggle (the shader `mix`es, so 0.5 proves it runs per-fragment rather than swapping a pre-greyed texture); a UI panel replaces the keyboard; and a "filter the whole frame" checkbox shows the other thing the API allows and raylib's example never does. `.memory = .managed`, FLAT twice-lifecycle census.

  **STILL OPEN for a future 2D shader:** only ONE user texture (group 1 is the batch's single `texture0`). A multi-sampler 2D shader would need the batch's bind group reworked.
- [x] `shaders_simple_mask` — DONE, **MERGED** into `shaders_multi_texture` with multi_sample2d: they are the SAME shader wearing two hats (sample two sources, produce a blend factor, mix) and only the factor differs. Mask branch = a third texture's luminance. Here the mask is **LIVE** (a radial gradient that follows the finger), which beats raylib's static mask image — you watch the two sources swap under the spotlight as you drag.
- [x] `shaders_texture_rendering` — DONE as a new member of the engine effect family (`src/shaders/effect_cubes_fs.zig` + `_io.zig`, raylib's `cubes_panning.fs`), surfaced as a `cubes` mode in the `shader_effects` gallery. **PURELY PROCEDURAL — it samples NOTHING**: every pixel comes from the UV and the clock. That IS raylib's example: it draws a BLANK texture through the shader, so the texture is only a canvas to rasterise over. It still DECLARES the family's sampler so it satisfies the binding contract and `effects2d` runs it with no special case. Technique: pan the UV with time, multiply by `divisions`, then `floor` = which cell / `fract` = where inside it (the whole tiling trick); each cell's contents snap-rotate 0->45deg->hold->back once a second, with the two MOVING quarters eased by a sine. Wrote a local `step()` (zimrmath has none, and it is one comparison — not worth growing the math module for one caller). raylib's GLSL mutates a FILE-SCOPE `angle` from inside a function; here the angle is RETURNED — same maths, no global state in a shader. Added a checker tint off the CELL index so the panning is legible on a phone (raylib's is flat grey).
- [x] `shaders_vertex_displacement` — **DONE (adapted).** zimr's vertex stage can't sample textures, so instead of a heightmap-texture VS, a grid mesh is rippled by stacked sine waves on the CPU and streamed via `updateMeshBuffer` (the dynamic_mesh path). Same living surface, engine-native. Solid+wireframe, phone OrbitCamera.

### core — 0 missing (cluster COMPLETE)
_SMALL UTILITIES — delta_time, random seq/values, scissor, smooth pixel-perfect, undo/redo, input action maps, hidpi/letterbox/viewport scaling (several may fold into responsive scale mode)._

- [x] `core_delta_time` — DONE as `delta_time` (ball crosses at a constant px/sec via `f.time.delta_time`; HUD shows smoothed FPS, frame time, elapsed). clearViewport + `.scale_mode=.fit`; smoke-clean (1 begin-pass/frame), standalone built.
- [x] `core_highdpi_demo` — **N/A on web (verified this session, reason recorded).** The sample's job is to visualise a high-DPI display: print `GetWindowScaleDPI()`, draw a "logical points" grid beside a "pixel" grid, and — its headline interaction — hop between monitors with `SetWindowMonitor`. On zimr's web target none of that is a gap or is even expressible: the canvas already resolves devicePixelRatio (`.scale_mode = .responsive`), the logical-vs-physical distinction is already exposed (`window.widthf()` = logical points vs `getSurfaceSize` = backing pixels, the exact pair the font atlas bakes against), and there is no multi-monitor `SetWindowMonitor` in a browser tab. Porting would either re-demonstrate something the engine does automatically or fake the monitor-hopping — so N/A, not a padded number.
- [x] `core_highdpi_testbed` — **N/A on web** — same determination as `core_highdpi_demo` (verified together): DPR handled by `.responsive`; logical/physical already exposed; no browser equivalent for the monitor-switching the testbed exists to exercise.
- [x] `core_input_actions` — **DONE as `input_actions`.** raylib's whole lesson is the ACTION MAP: game logic asks "is ACTION_UP down?" and an indirection layer decides which physical input satisfies it (raylib swaps between two keysets to prove the logic is identical). Phone has no keyboard, so the honest translation keeps the lesson and swaps the two *keysets* for two *input schemes* a touch screen actually has: **PAD** (a multi-touch D-pad + Fire — two thumbs give real diagonals) and **STICK** (a virtual analog stick whose knob offset past a dead-zone maps to the same four actions). Both fill the SAME `Actions` struct; the box update (`applyActions`, a PURE function) and the on-screen action read-out consume only that struct and can't tell which scheme produced it — the abstraction made tactile. Toggle schemes live. No engine primitive needed (the action map is a small in-example construct: raw touch/mouse in, logical `Actions` out); noted as the pragmatic phone port over inventing an engine action-map layer nothing else needs yet. `.memory = .managed` (UI font only); smoke ✓ PASS FLAT census; standalone 1.66 MB.
- [x] `core_random_sequence` — DONE as `random_sequence` (Fisher-Yates over an example-owned `std.Random` → rainbow bar chart, SPACE reshuffles; no global RNG). Standalone built for device confirm.
- [x] `core_random_values` — DONE as `random_values` (PRNG in State, `intRangeAtMost(-8,5)`, 2 s regen cadence; int→text via bufPrint). Standalone built.
- [x] `core_scissor_test` — DONE as `scissor_test` (GPU `beginScissorMode`/`endScissorMode` clips one screen-fill + text to a mouse-tracked 300px box; S toggles). **ROOT CAUSE of the on-device "BeginRenderPass while a pass is open" / invalid CommandBuffer:** the new examples called `z.beginDrawing(f.gl)`, which opens a SECOND render pass on top of the one the runtime already opens for the frame. The 2D frame primitive is `z.clearViewport(f, color)` (a full-screen clear rect drawn INTO the runtime's pass) — used by input_mouse, shapes_demo, srcrec_dstrec and ~165 other 2D examples; NONE of them call beginDrawing (that's for the 3D path). Fix: replaced `beginDrawing`(+`clearBackground`) with `clearViewport` in all three new examples. Confirmed IN-SANDBOX via smoke telemetry: `js_encoder_begin_render_pass=1`/frame (was 2), leak-clean deinit. (My earlier "clearBackground reopens the frame" guess was wrong — clearBackground was a red herring.)
- [x] `core_smooth_pixelperfect` — DONE as `smooth_pixelperfect` (RTT engine coverage). Pixel-art scene drawn into a 322x182 low-res render texture, composited scaled 2.5x. Camera split: INTEGER part offsets the scene inside the RT (edges land on virtual pixels = crisp), FRACTIONAL part shifts the whole scaled RT by sub-pixel SCREEN px (dest-position shift, not UV — so nearest sampling stays crisp while motion is smooth). RTT frame flow verified via smoke (3 begin/3 end passes balanced; leak-clean deinit). Device screenshot confirmed the RT sampler was LINEAR (soft edges) — root cause: `WgpuRenderTexture.create` hardcoded `mag/min_filter_linear = true`. **ENGINE WORK:** added a `nearest_filter` option to the RT CreateDesc + `z.loadRenderTextureEx(gl, w, h, nearest_filter)` (non-breaking; `loadRenderTexture` unchanged/bilinear). pixelperfect now loads with nearest → crisp. Matches raylib's default point filter. Regression-checked pipeline_rendertarget (still bilinear) smoke-passes. **Verified MECHANICALLY, not by eye:** at 2.5x on a high-DPR phone the nearest-vs-linear difference is nearly invisible in a screenshot, so two host tests in `src/tests/features_test.zig` pin the mapping instead — `nearest_filter=true` => `SamplerDesc.mag/min_filter_linear=false` (the bridge forwards exactly these bools to JS as "nearest"/"linear", so asserting the desc IS asserting the GPU filter), default stays bilinear, and mag/min must agree (a mismatch is the classic crisp-in/blurry-out bug). Negative-control checked: the test fails when the expectation is flipped. LESSON: when a visual difference is too subtle to eyeball on-device, pin the mechanism in a host test rather than asking Simon to squint.
- [x] `core_undo_redo` — DONE as `undo_redo` (typed text field + snapshot history; Ctrl+Z/Ctrl+Y walk the history, Backspace deletes). **ENGINE WORK this drove:** exported `z.getCharPressed` (the typed-character queue already existed in runtime.zig — `char_queue` + `pushChar` + `getCharPressed` — but wasn't exposed; added the wgpu_app wrapper + zimr export). Unblocks any text-input example. smoke-clean.
- [x] `core_viewport_scaling` — DONE as `viewport_scaling` (manual letterbox). Game renders into a fixed 640x360 RT (nearest), then each frame is scaled by the LARGEST factor that fits the real window, centred, black bars around it — aspect always preserved. One `Fit{scale, off_x, off_y}` value drives BOTH the draw (virtual->screen) AND the inverse mouse mapping (screen->virtual), so they can't disagree; a crosshair at the mapped cursor proves it. Runs `.scale_mode = .responsive` on purpose (the window must be the REAL device size for the letterbox math to have something to solve) — this is the by-hand version of what `.scale_mode = .fit` does at the engine level. smoke-clean (3 begin/3 end passes).
- [x] `core_window_letterbox` — **COVERED, not a fresh port (verified this session).** `examples/viewport_scaling` already ports exactly this mechanic — its own header says it ports raylib's `window_scale_letterbox`: render into a fixed design-resolution RenderTexture, scale by the LARGEST factor that fits, centre with black bars, aspect preserved, and map mouse coordinates BACK through the same transform for hit-testing in virtual space. That is `core_window_letterbox` (raylib's 640×480 RT + `virtualMouse` inverse map). Re-porting would duplicate — closed honestly. (The engine's `.scale_mode = .fit` is the window-level version of the same thing.)

### models — 3 missing
_bone_socket (attach-to-bone), animation_blend_custom, geometric_shapes (primitive mesh gallery)._

- [x] `models_animation_blend_custom` — DONE (zimr879). Per-bone blend of greenman's `2_move` (walk) + `3_attack`: upper-body joints (torso/arms/hands, by name) follow the attack while lower-body (hips/legs) keep walking; a checkbox flips to uniform 50/50. Reuses bone_socket's hierarchical CPU skinning + TRS sampling; blends LOCAL TRS per node (lerp T/S, nlerp R) then accumulates the hierarchy. Census-balanced.
- [x] `models_bone_socket` — DONE, its own example again (zimr877) using raylib's REAL CC0 rigged character. Loads `greenman.glb` (12-joint HIERARCHICAL skeleton, 4 clips) + `greenman_sword.glb`, plays `3_attack`, and sockets the sword to the `socket_hand_R` bone (found by NAME) via that bone's per-frame world matrix. Drove NEW engine-example capability: full hierarchical skeletal animation on the CPU — node tree walked parents-first, full TRS keyframe sampling (nlerp for R, linear for T/S), skin = invBind·world. Census-verified balanced. (zimr875 first did this on the 2-bone quad; zimr876 briefly merged it into `skinned_mesh`; zimr877 gives it the real character it deserves and returns `skinned_mesh` to pure skinning.)
- [x] `models_geometric_shapes` — **DONE.** 3D "Mesh Gallery": all GenMesh* primitives (cube/sphere/cylinder/cone/torus/knot/plane/hemisphere) on a grid, phone OrbitCamera (orbit/pan/pinch), solid/wireframe/both toggle. Exported the 5 missing generators (cylinder/cone/knot/plane/hemisphere) from the root.

### shapes — 0 missing (cluster COMPLETE)
_top_down_lights (tile shadow-caster + light volumes), recursive_tree (fractal), mouse_trail._

- [x] `shapes_mouse_trail` — DONE, **MERGED** into `shapes_procedural` (with shapes_recursive_tree) behind a UI mode switch. Both are 'draw many primitives from a simple rule' and share all the scaffolding, so folding them saves a whole wasm + a device round-trip (a UI example costs ~10s to build). Trail = ring of recent pointer positions, circles shrinking + fading with age; seeded on first touch so no comet streaks in from (0,0).
- [x] `shapes_recursive_tree` — DONE, merged into `shapes_procedural`. Grown ITERATIVELY (raylib calls it recursive but expands a queue — that's what keeps it bounded); angle/length/decay are live SLIDERS, so the parameter space is explorable by thumb instead of raylib's keys. Bounded twice (min branch length + buffer cap) so a wild slider can't hang the frame.
- [x] `shapes_top_down_lights` — DONE (raylib's 4/4-complexity shapes sample). 2D hard shadows: per-light MASK render texture = radial gradient minus the SHADOW VOLUMES, additively accumulated into a lightmap, then the scene is MULTIPLIED by it. Each light needs its own mask pass because a shadow belongs to ONE light and must be cut before that light joins the sum. A shadow volume is just a box edge extended away from the light — and only edges FACING AWAY cast, which for an axis-aligned box is four comparisons (no normals/dots), the trick that keeps it O(boxes). Key engine detail: **`beginTextureMode(gl, rt, null)` — a NULL clear is a LOAD**, which is what lets the accumulator survive across per-light passes. Also uses `beginBlendMode(.additive/.multiply)`, `gl.circleGradient`, `gl.triangleFan`. 15 begin/15 end passes per frame, balanced.

## N/A — out of scope (wasm32-wasi / WebGPU / single-canvas / phone-first)

- `core_automation_events` — input record/replay
- `core_clipboard_text` — clipboard API
- `core_compute_hash` — not a render demo
- `core_custom_frame_control` — web owns rAF
- `core_custom_logging` — log callback
- `core_directory_files` — no wasi fs listing
- `core_drop_files` — no OS drag-drop
- `core_keyboard_testbed` — desktop key matrix
- `core_monitor_detector` — multi-monitor
- `core_screen_recording` — OS capture
- `core_storage_values` — fs save/load
- `core_text_file_loading` — fs read
- `core_vr_simulator` — VR
- `core_window_flags` — desktop flags
- `core_window_should_close` — no window close on web
- `core_window_web` — web boilerplate
- `models_loading_iqm` — obscure format
- `models_loading_m3d` — obscure format
- `models_loading_vox` — obscure format
- `models_rlgl_solar_system` — rlgl matrix stack
- `embedded_files_loading` — zimr uses @embedFile
- `raylib_opengl_interop` — raw GL
- `rlgl_standalone` — rlgl w/o raylib
- `shaders_hot_reloading` — no fs watch on web
- `shapes_rlgl_triangle` — raw rlgl
- `textures_clipboard_image` — clipboard API

**Engine capability added (vertex texture fetch):** the shader schema can now
declare a sampler binding vertex-visible via `Sampler2D(.tag, .{ .stages =
.{ .vertex = true } })`. `SamplerConfig.stages` -> `SamplerSlot` -> `ResolvedField`
-> the bind-group-layout entry visibility (shader_runtime_wgpu.zig). Combined with
the existing `sampleLevel` builtin (-> `textureSampleLevel`, derivative-free), zimr
can sample textures in vertex shaders like other engines. Non-regressive (defaults
fragment-only). NEXT: rebuild shaders_vertex_displacement as a real GPU vertex-
shader height-texture displacement (the faithful technique), replacing the CPU stopgap.

**VTF exerciser — WORKING (smoke-verified).** Vertex texture fetch is fully functional end-to-end. The 3-layer capability (stages visibility, `zsample2d_level` accessor codegen, zspv `OpImageSampleExplicitLod` rewrite) plus the `vertex_texture_test` exerciser all pass `smoke-test -Dfocus=vertex_texture_test`. The shader pipeline (compile -O ReleaseFast -> zspv --rewrite-samplers-wgsl -> spv2wgsl) emits `textureSampleLevel(warp, warp_sampler, uv, lod)` inside the `@vertex` function. Two non-shader bugs had masked this: a 162-col line in build.zig tripping the line-length lint gate (now split multi-line), and a `u0` local shadowing Zig's `u0` primitive in the example (renamed s0/t0). Standalone HTML built for device visual verification (warped checkerboard grid).
