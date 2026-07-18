# audit_cleanup_notes.md — running notes for the post-port audit

Standing request (turn 1167): after the PBR side-by-side ships and the
remaining GL-only examples are ported, **WebGL gets deleted and the whole
tree gets a full audit + cleanup**.  This file collects, AS WE WORK, the
things we don't like — duplications, hacks, seams that exist only because
the GL path still breathes.  Append candidates the moment you notice them;
sort/prioritize when the audit actually opens.  One entry per item:
what it is, why it exists today, what the cleanup looks like.

## A. Delete-with-GL (mechanical once GL dies)
- **`gen_shader_externs.zig` dual emission** — every generated `*_externs.zig`
  carries BOTH the legacy `setup()` + module-scope extern decls (GLSL-era
  shader shape) AND the new `IoT`/`Out`/`installSpirvEntry` API.  Once every
  shader is on the `shaderMain(io) Out` shape and GL is gone, delete the
  legacy emission path — roughly halves the generator and the generated files.
- **`engine_shaders` `.glsl` gravestone wiring** (build.zig) — every engine
  shader still registers a `<name>.glsl` anonymous import pointing at
  `_deleted_glsl_placeholder.glsl` so `rlgl.zig`/`render.zig` `@embedFile`s
  resolve.  Dies with rlgl/render.
- **`zigTypeForElem`/GLSL-name plumbing in the codegen** — the `texture0`
  naming convention ("strips to `uniform sampler2D texture0` in the
  cross-compiled GLSL") and other GLSL-compat naming constraints can be
  revisited once WGSL is the only target.

## B. Structural simplifications (need design, big wins)
- **TWO software rasterizers.**  `rlsw.zig` (7.2k lines) is the fixed-function
  GL-style rasterizer (matrix stacks, immediate mode, texture units, blend/
  cull/scissor codecs).  `rlsw_shader.rasterizeTriangles` is the NEW
  programmable rasterizer (VS/FS modules, perspective-correct varyings, depth
  as of turn 1167).  Long-term the fixed-function path should be a DEFAULT
  SHADER on the programmable path (exactly how real GPUs killed fixed
  function) — one rasterizer, one depth/blend/scissor implementation.
  rlsw's immediate-mode API stays as a front-end that builds vertex streams.
- **pbr3d's `FsUbo` host mirror duplicates `pbr_fs_io.Ubo`.**  The engine
  module can't import `src/shaders/pbr_fs_io.zig` because example-side shader
  bundles own those files (one-file-per-module).  Fix candidate: give the io
  schemas a named module (`pbr_io`) imported by BOTH zimr_wgpu and the
  bundles, and have shader sources import their io BY NAME instead of
  relatively — then `FsUbo` deletes and the shader's `Ubo` is the single
  source of truth (also closes the standing "std140 mismatch should be a
  compile error" ask from finishing_webgpu.md §0).
- **`pbr3d.drawInApp` deleted in favor of RTT compositing** (this turn) —
  watch for other "draw into someone else's pass" couplings; the RTT +
  fresh-pass pattern is the sanctioned one.  `wgpu_app.appOf` + `WgpuGl`
  pub-ness were exposed FOR drawInApp; re-privatize if nothing else uses them.

## C. Smaller cleanups
- **CPU `TextureRef` sampler is v1**: nearest-only, single global wrap mode
  (repeat as of turn 1167).  The schema's `Sampler2D(.kind, .{config})`
  already carries per-sampler config — thread it through so CPU sampling
  honors the same filter/wrap the GPU sampler uses (bilinear especially;
  the CPU half of side-by-sides visibly stair-steps).
- **`rlsw_shader.dispatchFragmentShader` keeps a reserved `stride_x`**
  (`_ = stride_x`) — either implement non-canonical strides or drop it.
- **`pbr3d.loadGltf` leaks the meshesFromGltf arrays** (documented at top of
  file) — tighten ownership when touching the loader.
- **Light counts duplicated 3×**: `pbr_common_io.max_*_lights`, plain consts
  in `pbr_fs.zig`, and `pbr3d.max_*_lights`.  After the io-module
  restructure (B above) they collapse to one.
- **`ui.zig` (kept, wgpu-era imgui) imports `drawing.zig` (condemned GL
  monster)** — discovered turn 1167 when the wgpu wasm's module graph
  claimed `shaders/pbr_vs_io.zig` THROUGH that edge.  Stop-gapped with a
  name-only `TangentWantingSchema` in drawing.zig; the GL deletion must
  sever ui→drawing entirely (audit what ui actually uses from it).
- **No `destroyBindGroup` across the JS bridge** — `Renderer2D.
  updateRegisteredTexture` (t1168, the resizable-CpuFramebuffer enabler)
  drops the old bind-group handle per resize.  Bounded by rotation count,
  but the bridge should grow destroy ops for bind groups (and audit which
  other handle types lack one).
- **CpuFramebuffer + registry lifecycle** — resize landed (t1168); a real
  `deinit` (texture + registry slot release) is still missing, as is a
  registry `unregister`.  Fine while apps are page-lifetime; needed before
  any "many short-lived CPU surfaces" use case.
