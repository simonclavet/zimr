# webgpu_control.md — complete WebGPU control + raygpu example parity

## The goal (one sentence)
Give a zimr app **complete, low-level WebGPU control** — bring-your-own render and
compute pipelines, custom vertex layouts, arbitrary bind groups, render-to-texture
chains, storage textures, MSAA — **without giving up the easy path** (immediate-mode
`drawCircle`/`drawCube`, Zig shaders, designated-struct-literal APIs), and reach the
same example/feature coverage as raygpu (`/mnt/.../raygpu-master`, 55 examples).

The test of success: in ONE `beginDrawing` frame you can `drawText(...)` for the HUD,
run a custom post-processing pipeline for a bloom pass, and dispatch a compute shader
that writes a storage texture — composing freely, no engine fork required.

## Why now / what's the gap
raygpu's distinctive surface is its low-level escape hatch on top of the raylib
convenience API: `LoadPipeline(wgsl)`, `LoadVertexArray()` + `VertexAttribPointer`,
`SetShader{Uniform,Texture,Sampler}` by reflected name or index, `BeginShaderMode` +
`DrawArrays{,Instanced,IndexedInstanced}`, `LoadComputePipeline` + `DispatchCompute`,
`LoadRenderTextureEx(..,sampleCount,..)`, storage textures.

zimr already has almost all the **plumbing** but exposes **none of it to app code**:
- `src/gpu.zig` — descriptor encoding (RenderPipelineDescriptor / BindGroupEntry /
  Vertex*), the pipeline cache, per-frame GPU state. Engine-internal.
- `src/shader_introspect.zig` — reflected binding info (uniform/texture/sampler/
  storage/storage_texture). Already exists → powers "bind by name".
- `src/bridge.zig` — render-pass descriptors already accept `sample_count`
  (MSAA, ~line 1787/1811) and a storage-texture binding type (5).
- `src/wgpu.zig` — the handle layer (buffers, textures, pipelines, bind groups).
- The Zig→SPIR-V→WGSL shader toolchain (`ShaderPipeline` build helper).
- GPU skinning already works (`wgpu_skinned_mesh`).
The only public pipeline export today is `PipelineCache` (engine-internal). There is
**no app-facing custom-pipeline / material / VAO API**. That API is the keystone of
this whole plan; the example parity falls out of it.

## Design principles (the zimr way — non-negotiable)
- **Zig shaders are the default, raw WGSL is the documented escape hatch.** A custom
  pipeline takes a shader as EITHER a Zig `.vs.zig`/`.fs.zig` module (compiled through
  the existing SPIR-V→WGSL path) OR a raw WGSL string. Both reach the same descriptor.
  We do NOT add a GLSL front end (see "declined").
- **Designated struct literals for state, not setters.** Blend/depth/cull/topology/
  sample-count/constants are fields of a `PipelineDesc`, configured once at init.
- **Explicit state threading, no globals.** A `Pipeline` owns its handles; the app
  holds it and threads it. Re-entrant like the rest of the engine.
- **Compose with the immediate-mode renderer**, don't replace it. A custom pipeline
  draws inside the same `beginDrawing`/`beginMode3D` pass as `drawCircle`.
- **Build on the existing layers** (gpu.zig / wgpu.zig / shader_introspect / bridge),
  surfacing them — not a parallel stack.
- **Headless-typecheckable**; descriptor construction unit-tested without a browser
  (gpu.zig already is); visuals confirmed in a `-standalone` on device.

## The keystone API (sketch — to be refined against gpu.zig)
A new public module, e.g. `src/material.zig`, re-exported from `zimr.zig` as
`z.VertexLayout`, `z.Pipeline`, `z.ComputePipeline`, `z.RenderTexture`, `z.effects`.

```zig
// 1. declarative vertex layout — multiple buffers, per-instance attributes
const layout = z.VertexLayout.init(&.{
    .{ .buffer = 0, .location = 0, .format = .f32x3, .offset = 0,  .step = .vertex },
    .{ .buffer = 0, .location = 1, .format = .f32x2, .offset = 12, .step = .vertex },
    .{ .buffer = 1, .location = 2, .format = .f32x2, .offset = 0,  .step = .instance },
});

// 2. a pipeline — Zig shader (default) or raw WGSL (escape hatch) + explicit state
var pipe = try z.Pipeline.init(f.gpu, .{
    .shader   = .{ .zig = my_shader },          // or .{ .wgsl = wgsl_src }
    .layout   = layout,
    .targets  = &.{ .{ .format = .bgra8, .blend = .alpha } },
    .depth    = .{ .enabled = true, .write = true, .compare = .less },
    .cull     = .back,
    .topology = .triangles,
    .samples  = 4,                              // MSAA
    .constants = &.{ .{ "green", 0.8 } },       // pipeline-overridable constants
});

// 3. bind by reflected name (shader_introspect) OR explicit @binding index
pipe.setUniform("Perspective_View", &mvp);
pipe.setTexture("colDiffuse", tex);
pipe.setSampler("texSampler", smp);
pipe.setStorage("modelMatrices", mats_buf);     // storage buffer

// 4. draw inside the normal frame
pipe.bindVertex(0, vbo);
pipe.bindVertex(1, instance_buf);
pipe.drawIndexedInstanced(ibo, index_count, instance_count);  // also draw / drawInstanced
```

Render targets + effects building blocks (the "easy complicated effects" half):
```zig
var rt = try z.RenderTexture.init(f.gpu, w, h, .{ .format = .rgba8, .samples = 4 });
{ const pass = rt.begin(f); defer pass.end(); /* draw scene into rt (MSAA resolves) */ }

var bloom = try z.effects.Bloom.init(f.gpu, w, h);   // downsample → blur → composite
bloom.apply(f, rt.color(), .{ .threshold = 1.0, .intensity = 0.7 });

var stex = try z.StorageTexture.init(f.gpu, w, h, .rgba8);  // compute writes pixels
my_compute.bindStorageTexture("tex", stex);
my_compute.dispatch(w / 16, h / 16, 1);
z.drawTexturePro(f, stex.asTexture(), src, dst, ...);       // render samples it
```

## raygpu → zimr coverage matrix (all 55)
Legend: ✅ have · ~ partial (exists but not as this) · ❌ missing → build it · ⛔ out of scope/N-A · 🚫 declined.

### pipeline_* — the keystone family (mostly ❌; this is the point of the plan)
| raygpu | zimr | target |
|---|---|---|
| pipeline_basic | ✅ | `wgpu_pipeline_basic` — custom WGSL/Zig pipeline + VAO + DrawArrays |
| pipeline_uniforms | ✅ | `wgpu_pipeline_uniforms` — reflected uniform/texture/sampler bindings |
| pipeline_instancing | ~ (engine instancing) | `wgpu_pipeline_instancing` — per-instance attrs, DrawIndexedInstanced |
| pipeline_constants | ✅ | `wgpu_pipeline_constants` — pipeline-overridable `override` constants |
| pipeline_settings | ✅ | `wgpu_pipeline_settings` — blend/depth/cull/MSAA state, RT compare |
| pipeline_spirv | ~ (whole path is SPIR-V) | `wgpu_pipeline_zig_shader` — a Zig shader AS a custom pipeline |
| vao_multibuffer | ✅ | `wgpu_vao_multibuffer` — multiple vertex buffers, swap a buffer per attr |

### textures_* (effects + texture features)
| raygpu | zimr | target |
|---|---|---|
| textures_storage | ❌ (binding type 5 plumbed) | `wgpu_storage_texture` — compute writes a texture, render samples (KEY) |
| textures_bloom | ✅ | `wgpu_bloom` — multi-pass post (downsample/blur/composite) (KEY) |
| textures_array | ✅ | `wgpu_texture_array` |
| textures_cubemap | ~ (skybox) | `wgpu_cubemap` — general cubemap sampling |
| textures_mipmap | ✅ | `wgpu_mipmap` — mip generation + LOD |
| textures_formats | ❌ | `wgpu_texture_formats` — format coverage matrix |
| textures_generate | ~ (procgen_noise) | covered; optional `wgpu_texture_generate` |

### core_* (window/camera/RT/MSAA/etc.)
| raygpu | zimr | note |
|---|---|---|
| core_window / core_browser_extent | ✅ | hello_world, basic; domCanvasSize |
| core_shapes | ✅ | shapes_showcase |
| core_camera2d / core_camera3d | ✅ | camera2d, cube3d, first_person_camera |
| core_rendertexture | ✅ | render_texture (RenderTexture API generalises it) |
| core_fonts | ✅ | text_layout, assets |
| core_msaa | ✅ | `wgpu_msaa` — falls out of `.samples` on RenderTexture/Pipeline |
| core_cursor | ~ (host fn exists) | `wgpu_cursor` — cursor styles |
| core_resizable / core_vsync_fullscreen / core_windowtitle | ~ | minor; fold into a `wgpu_core_window` showcase |
| core_headless | ⛔ | native `sw-*` rasterizer proofs already cover headless |
| core_multiwindow(_multiplatform) | ⛔ | single canvas; out of scope |
| core_screenrecord | ⛔ deferred | MediaRecorder capture; low priority |

### models_* / 3D
| raygpu | zimr | target |
|---|---|---|
| models_cube | ✅ | cube3d, textured_cube |
| models_glb | ✅ | gltf_textured, damaged_helmet |
| models_lights | ✅ | lambert_demo, pbr_demo |
| models_gpu_skinning | ✅ | skinned_mesh (already GPU skinning) |
| models_raytracing | ✅ | rt_shader, raytracer, models_raytracing |
| models_obj | ✅ | codecs.obj + wgpu_obj_simple, wgpu_obj_bunny |
| models_forwardkinematics | ✅ | wgpu_forward_kinematics (device-confirmed) |

### input_*
| raygpu | zimr | target |
|---|---|---|
| input_keys / input_text / input_multitouch_gesture | ✅ | input_keys, text_field, gestures_testbed |
| input_gamepad | ❌ | Gamepad API in bridge + `wgpu_gamepad` |

### shaders_* / tooling
| raygpu | zimr | note |
|---|---|---|
| shaders_basic | ~ | julia/rt_shader; subsumed by pipeline_basic |
| shaders_lightmap | ❌ | optional `wgpu_lightmap` |
| shader_inspection | ✅ | reflectWgslBindings + wgpu_shader_inspection |
| shaders_glsl / glsl_to_wgsl | 🚫 declined | zimr is Zig→WGSL; no GLSL front end (state this in readme) |

### compute / benchmark / misc
| raygpu | zimr | note |
|---|---|---|
| compute | ✅ | compute_particles/smoke, fluid_gpu/sort (kompute) |
| benchmark_cubes | ❌ | `wgpu_benchmark_cubes` — many cubes + the profiler panel |
| benchmark_tilemap | ~ (tile_smoke) | `wgpu_benchmark_tilemap` |
| split_screen_camera3d | ✅ | split_screen |
| async / rlfunctions | ✅ | boot is async; raylib coverage spread across examples |
| memory_vma_allocator / plain_wgvk / surface_wgvk | ⛔ N-A | Vulkan VMA + their wgvk Vulkan backend; not applicable to the browser |

## Phased build-out (each phase ships + proves headless, visual on device)
**Phase 1 — the public pipeline API (keystone).** Build `src/material.zig`
(`VertexLayout`, `Pipeline`, bind-by-name via shader_introspect, draw/instanced/
indexed). Surface gpu.zig's descriptor encoder + the bridge's existing pipeline path.
Ship examples: pipeline_basic, pipeline_uniforms, vao_multibuffer, pipeline_instancing,
pipeline_constants, pipeline_settings, pipeline_zig_shader. Unit-test descriptor
building headless.

**Phase 2 — render targets & effects.** Generalise render_texture into `RenderTexture`
(with `.samples` → MSAA resolve). Add `StorageTexture` and the compute→texture path.
Add `z.effects.Bloom` as the first composable post helper. Ship: msaa, storage_texture,
bloom.

**Phase 3 — texture features.** texture_array, cubemap (general), mipmap, formats.

**Phase 4 — model/3D parity.** Pure-Zig OBJ loader + models_obj; forward_kinematics;
(skinning/lights/raytracing already have). Optional lightmap.

**Phase 5 — input/core parity.** Gamepad (bridge + example); cursor; a
core_window showcase (resizable/title/fullscreen); benchmark_cubes/tilemap (showcase
the profiler).

**Phase 6 — tooling.** shader_inspection (dump reflected bindings). GLSL path declined.

## Explicitly declined / out of scope
- **GLSL input** (shaders_glsl, glsl_to_wgsl): contradicts the Zig-shader thesis. We
  translate Zig→SPIR-V→WGSL, not GLSL→WGSL. Note this stance in readme.html.
- **multiwindow**, **plain_wgvk / surface_wgvk** (their Vulkan backend), **vma_allocator**
  (Vulkan memory allocator): backend/native concerns with no browser analogue.
- **headless**: already covered by the native `sw-*` rasterizer proofs.
- **screenrecord**: deferred (MediaRecorder), not core to the control story.

## Cross-cutting deliverables
- Update `readme.html`: a new "Complete WebGPU control" section documenting the
  pipeline/material API and the effects helpers, plus the GLSL-declined note. Add the
  new examples to the examples table.
- Every new public type gets headless descriptor/typecheck tests; every example gets a
  `wgpu-<name>` + `-standalone` step; visuals confirmed on device.
- Keep the immediate-mode renderer the front door; the pipeline API is the side door
  that opens onto the same room.
