# shaders_deferred_render port — MRT arc plan

Raylib parity target: G-buffer FS writing THREE outputs (location 0 position.xyz,
1 normal.xyz, 2 albedo.rgb+spec.a) into three float textures, then a fullscreen
lighting pass sampling all three + N point lights. GPU-only for parity (a
software/comptime deferred flagship is a separate, later idea).

Current engine reality (surveyed zimr509): every front is SINGLE color target.

## STEP 1 — spv2wgsl + DSL: multi-output fragment shaders
- shadermath FS `Out` struct with several `@Vector(4,f32)` fields → SPIR-V emits
  several Output-class variables with Location decorations.
- Verify/extend spv2wgsl: emit a WGSL return struct `@location(0..N)` (the VS
  path already emits multi-field output structs — expected small).
- gen_shader_externs: `Out` already supports multiple fields for VS; confirm the
  FS side + installSpirvEntry do not assume one output.
- New shaders: `gbuffer_vs/fs.zig` + `deferred_shading_vs/fs.zig` (+ *_io.zig).
  gbuffer FS outs: g_position, g_normal, g_albedo_spec. Lighting FS samples 3
  TextureRefs + a light UBO array (fixed N, e.g. 4 lights like raylib).
- Note: raster_shader.rasterizeTo* picks THE vec4 out field — multi-output FS is
  GPU-only until a (later) MRT story for the software path. Guard with a clear
  compile error if a multi-out FS reaches the software rasterizer.

## STEP 2 — pipeline: N color targets
- `encodeRenderPipelineDescriptor`/StateCombo carry one `color_format`; WebGPU
  `fragment.targets` is an array. Add `color_formats: []const TextureFormat`
  (StateCombo keeps the single hot-path; a new descriptor field feeds the array),
  bridge builds N target entries (blend on target 0 only, raylib-style).

## STEP 3 — pass encoding: N color attachments
- `js_encoder_begin_render_pass(encoder, color_view, ...)` takes one view.
  Add an MRT variant taking a wasm-memory pointer to `[n]u32` view handles +
  count (bridge reads wasm memory directly — existing blob pattern); one
  clear color + load/store applied to all, or per-attachment array later.
- zimr-level: `beginTextureModeMrt(gl, rts: []const RenderTexture, clear)` or a
  GBuffer struct owning 3 rgba16_float RTTs + one shared depth.

## STEP 4 — the example `wgpu_deferred_render`
- Scene: raylib's (cube field + orbiting camera + 4 colored point lights,
  keyboard toggles ALBEDO/NORMAL/POSITION/SHADING debug views → our launcher
  tap-to-cycle).
- Pass A: geometry → G-buffer (MRT). Pass B: fullscreen triangle sampling the
  three maps + lights UBO → canvas RTT. Debug views = blit one map.
- Gate: standalone build + `smoke-test -Dfocus=wgpu_deferred_render` (expect
  begin_render_pass=2+, draw profile), device verify by Simon.

Order strictly 1→4; each step is one gated turn-ish unit. STEP 1 is the deepest
(transpiler); if it stalls, 2+3 are independent and can land first.
