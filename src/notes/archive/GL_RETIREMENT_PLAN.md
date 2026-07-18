# GL RETIREMENT PLAN (t1173)

The port queue cleared at t1172: every GL example is ported, superseded with
documented reasons, or deferred to a named arc.  This document is the deep
study of the build process + module graph, and the phased plan to retire the
WebGL path.  Each phase ends with the full gate battery green (`zig build
test`, tier-a smoke, lint 0).  Improvements spotted during the study are
folded in where they belong in the order.

## THE MAP (what the study found)

### Who is condemned (lint's `isSkipped`, tools/lint_zimr.zig ~899)
- src/{zimr, rlgl, gl, gl_iface, drawing, test}.zig
- every top-level `examples/<name>.zig` EXCEPT `_fs.zig`/`_vs.zig` shader
  sources (those are LIVE — the shader pipeline compiles them and wgpu
  examples @embedFile their .wgsl outputs).

### What keeps GL code alive today (the full consumer audit)
1. **`zimr_wgpu` → ui.zig → {drawing.zig, rlgl.zig, zimr.zig}** — the wgpu
   wasm graph still REACHES the GL backend.  ui.zig uses:
   - `drawing.text.{FontCache, draw, drawWithFont, measure, measureWithFont,
     warned_text_no_font}` and `drawing.shapes.{ShapesTextureState +
     11 draw fns}` — these are the LIVE, backend-generic (`gl: anytype`)
     2D subsystems, trapped inside the condemned file;
   - `drawing.shaders.begin/endScissorMode` + `rlgl.*` (matrix stack,
     framebuffer) — ui's GL RENDER BRANCH only;
   - `zimr.{Frame, run}` — GL app types (the `zimr.md` hit in an earlier
     symbol dump was a grep artifact from a doc filename in comments).
2. **`wgpu_app.zig` → drawing.zig** directly: `drawing.text` (~2213,
   bakeFontAtlas/FontAtlas/drawWithFont/measureWithFont),
   `drawing.shapes` (~2226, ShapesTextureState), and ONE call to
   `drawing.textures.unloadImage` (~2368, freeing the baked font atlas).
3. **`runtime.zig` is NOT purely GL**: zimr_wgpu + wgpu_app import its
   `input`, `gestures`, `core` (WindowState), `effects.rng` namespaces.
   runtime.zig (6.7k lines) hosts live subsystems beside the GL AppBridge.
   Cure: PRUNE the GL parts in P5, keep the file (it is not lint-doomed).
4. **Host test suite** (`test_files` = src/tests.zig → src/tests/*.zig) is
   the only remaining COMPILE of the GL stack: app_bridge_test (zimr +
   runtime_assembly), ext_storage_test (zimr), features_test (zimr),
   leak_test (drawing.textures/models + runtime), multiapp_test (runtime),
   scene_test (scene).  These test GL-era systems and need per-file
   adjudication in P5a — not blanket deletion.
5. **The docs library is `zimr_mod`'s ONLY compile consumer**
   (build.zig ~4066): autodoc currently documents the DYING GL API.
6. **sw_* host steps build `src/zimr.zig` natively**: sw-mandelbrot,
   sw-julia, julia-gallery each create a zimr module from the GL umbrella.
   But their actual surface is tiny: `codecs.png.encode, math, rlsw,
   rlsw_shader, gpu_iface, shader_runtime_wgpu, wgpu`.
   sw-engine-shader already uses the GL-free `sw_runtime.zig`
   (rlsw + rlsw_shader + codecs + autoConnect).  These six host demos
   (sw_mandelbrot, sw_julia, julia_gallery, comptime_julia,
   comptime_mandelbrot, sw_engine_shader) are USEFUL — the native
   SW-dispatch PNG demos — and are KEPT + migrated, not deleted.
7. **GL examples are already build-dark**: no step compiles or typechecks
   the top-level examples (the "example loop" comments in build.zig ~427
   are stale ghosts of removed machinery).  The GLSL path is already
   gated: `old_3d_shaders` placeholder block (~640-690), GLSL placeholder
   wiring in the host-test loop (~3650), `_deleted_glsl_placeholder.glsl`,
   buildaux `check-glsl-header`.
8. **drawing.zig anatomy** (18.5k lines): shapes 30-2868, textures
   2869-9119, text 9120-11958, models 11959-18069, shaders 18070-end.
   text's 12 rlgl refs are ALL in FontCache's GL texture upload/unload;
   shapes' 43 are GL wrappers + ShapesTextureState GL init.  The fns the
   wgpu side instantiates are clean (`gl: anytype` laziness).
9. **GL-era middle layer not in the doomed list but GL-only**: render.zig,
   scene.zig, gpu.zig, runtime_assembly.zig, shader_runtime.zig (the GLSL
   one — `shader_runtime_wgpu.zig` is separate and LIVE).  Reachable only
   via zimr.zig + the host tests.  They JOIN the deletion in P5b.

## THE PHASES (most logical order)

**P1 — Pure-move extraction (the keystone, zero behavior change).** ✅ DONE t1173
Move the `text` and `shapes` namespaces VERBATIM out of drawing.zig into
`src/text2d.zig` and `src/shapes2d.zig` (each keeps a transitional
`rlgl.zig` import for the GL-only fns — severed in P5d, when their GL
consumers are gone, so nothing alive ever breaks).  drawing.zig replaces
the blocks with `pub const text = @import("text2d.zig");` re-exports so
every GL consumer compiles unchanged.  wgpu_app.zig + ui.zig repoint to
the new files directly.  wgpu_app's single `drawing.textures.unloadImage`
call repoints to image.zig's unloadImage IF the impls free identically
(verify); else a tiny local free.  Why first: ui must have a live home
for text/shapes before its GL branch can be severed (P4), and the move is
mechanically safe while everything still compiles both ways.

**P2 — sw_* host-step migration (independent early win).** ✅ DONE t1174
Extend sw_runtime.zig with `math` (zm), `gpu_iface`,
`shader_runtime_wgpu`, `wgpu` re-exports; repoint sw_mandelbrot /
sw_julia / julia_gallery (example source: `@import("zimr")` →
`@import("sw_bundle")`; build.zig: replace their zimr_native_mod wiring
with sw-engine-shader's bundle wiring).  Add a lint `isSkipped` ALLOWLIST
for the six live host demos (they become style-enforced; fix what
surfaces).  After P2, nothing outside docs + tests builds zimr.zig.

**P3 — docs retarget (improvement: autodoc documents the LIVE API).** ✅ DONE t1174 (GLSL gravestone wiring + placeholder file + check-glsl-header survive until P5: the host-test modules still resolve render.zig's .glsl embeds)
docs_lib root_module: zimr_mod → zimr_wgpu_mod.  Then zimr_mod /
zimr_mod_smoke have zero consumers: delete their creation, the GLSL
placeholder wiring, the old_3d_shaders gravestone block, the
engine-shader GLSL entries, buildaux `check-glsl-header` + its fixture
step, `src/shaders/_deleted_glsl_placeholder.glsl`, and the stale
"example loop" comments.  Build graph shrinks; configure gets simpler.

**P4 — Sever ui.zig's GL branch.** ✅ DONE t1175 (details in PORT_PLAN; ui.zig
no longer imports rlgl/drawing/zimr — Gl selector = WgpuGl | TestGlStub)
Remove ui's rlgl import, the GL render path (the drawing.shaders scissor
callsites live only there), and the zimr.{Frame, run} integration.  How
ui dispatches per-backend needs reading at execution time (likely
comptime on the gl type); the wgpu UiHost path is the survivor.  After
P4 the zimr_wgpu graph is GL-free except text2d/shapes2d's transitional
rlgl import.

**P5 — THE DELETION.** ✅ DONE t1176 (full account in PORT_PLAN).
Deleted: src/{zimr,rlgl,gl,drawing,test,render,scene,gpu,runtime_assembly,
shader_runtime}.zig · 4 GL test files · 138 top-level GL examples · 19 old
3D shader sources (+io) · the GL web pipeline (zimr.ts, host.html,
index.html + their build blocks) · check-glsl-header. renderer_trait.zig SURVIVED
(WgpuGl's live comptime trait — only the GlAdapter section died).
textures-CPU merged into image.zig; models-CPU into draw3d.zig (leak_test
exercises the live libraries now). runtime.zig kept whole minus the four GL
camera-mode fns; the screen↔world projection pair ported to explicit
ClipPlanes params. refAllDecls-everywhere (Simon t1176) implemented in
tests.zig — surfaced + fixed a whole stratum of never-analyzed rot.

**Module collapse `zimr_wgpu` → `zimr`** ✅ DONE (post-arc session). With GL gone, the
wgpu module reclaimed the `zimr` name: renamed `src/zimr_wgpu.zig` → `src/zimr.zig`,
updated all 148 example imports + 2 src imports + 3 relative-path test imports + build.zig
(module name `"zimr"`, root path, and the `zimr_wgpu_mod` → `zimr_mod` var). Apps now
`@import("zimr")`. The JS bridge `src/web/zimr_wgpu.ts` keeps its name (separate concern;
TS rename is optional follow-up). Verified: gate 0/277, `zig build test` green (corpus
88/88), `wgpu-basic` wasm built. claude.md retargeted; the `files.md` catalog still lists
the old path (regenerate later). This closes the GL-retirement capstone (PORT_PLAN §1.5
"collapse zimr_wgpu→zimr").

**P6 additions from P5:** collapse engine_shaders to wgsl-primary naming
(drop the inert .glsl placeholder names + gravestone + per-consumer glsl
wiring); wgpu leak/multiapp GPU-resource coverage (returns with the bridge
destroy-ops item).
(a) Test adjudication, file by file: app_bridge/scene/multiapp die with
    their systems; ext_storage/features/leak — port the generic parts to
    wgpu equivalents where the concept survives (leak tracking!), delete
    the rest; prune tests.zig (gl_iface line etc.).
(b) Delete src/{zimr, rlgl, gl, gl_iface, drawing, test}.zig + the GL
    middle layer (render, scene, gpu, runtime_assembly, shader_runtime —
    NOT shader_runtime_wgpu) + prune runtime.zig down to its live
    namespaces (input/gestures/core/effects).
(c) Delete top-level GL example .zig files EXCEPT: `_fs/_vs/_io` shader
    sources, the six live host demos, `shared/`, assets.  The original
    examples/skinned_mesh_data.zig dies (copied into the wgpu dir at
    t1172).  examples/gallery.zig (GL gallery) dies.  Check src/web/ for
    GL-bridge TS remnants at execution time.
(d) Prune text2d/shapes2d: delete the rlgl-using GL wrapper fns, drop the
    rlgl import — the FINAL sever.
(e) Bookkeeping: lint isSkipped collapses to the allowlist logic;
    test_files; PORT_PLAN + claude.md + readme.

**P6 — Post-delete improvement program** — ADD (Simon t1175, giant-files /
flat-DAG philosophy): merge single-parent files into their only importer.
Census candidates (verify at execution): draw_points.zig, rlsw_adapter.zig,
shader_compile.zig, storage_buffer.zig, uniform_buffer.zig, pbr3d.zig (all
← zimr_wgpu.zig only); double_it.zig ← compute_host.zig; wave_fs_io.zig ←
shader_runtime_wgpu.zig.

**P6 — original program** (audit_cleanup_notes.md):
two-rasterizers collapse — **now planned in detail + COMMITTED in
`src/notes/software_rasterizer_oracle.md` (2026-06-16): Plan B only** (one
single-threaded scalar "Reference" rasteriser that is spec + engine + teaching
device; tiled/parallel "Plan A" rejected because deployment is single-threaded
wasm and the GPU is the speed path; fixed-function `rlsw` becomes a comptime
shader on B with no perf regression; SIMD128/tiling deferred as optional opts
gated by a bit-exact diff vs scalar B). Phase 0 (build the `wgpu_helmet_sw`
standalone as the before-baseline) done 2026-06-16. Remaining P6 cleanups:
gen_shader_externs single emission, bridge destroyBindGroup/unload ops,
CpuFramebuffer deinit/unregister, gltf symmetric mesh free, TextureRef v2
bilinear.

## RISK REGISTER
- Anything importing drawing/zimr that this study missed → every phase
  ends with `zig build test` + tier-a + lint; grep-audit before each
  delete.
- The six host demos' style debt surfaces at P2 (they were lint-skipped).
- ui.zig's backend dispatch shape is the one structure not yet read in
  full — P4 starts with that read.
- Keep: all `_fs/_vs/_io` shader sources, `examples/shared/`, assets,
  prebuilt/, the six host demos, runtime.zig's live namespaces,
  shader_runtime_wgpu.zig, sw_runtime.zig.
