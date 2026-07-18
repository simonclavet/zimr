# Phase F port recipe

Step-by-step for porting an IoT-pattern shader to both backends. Each recipe
section is ~30 minutes; the patterns are fixed at this point.

---

## Recipe 1: Fractal-style (Ubo only, no textures)

Examples: `mandelbrot_fs`, `julia_fs`, `mandel_julia_fs` (all done).

### A. Native CPU side (Mode 3)

1. Create `examples/<name>_fs_bundle.zig` (3 lines):
   ```zig
   pub const fs = @import("<name>_fs.zig");
   pub const io = @import("<name>_fs_io.zig");
   ```

2. Add a build target in `build.zig`. Copy the `sw-mandelbrot-pipeline`
   block; substitute the shader name. The block hard-codes:
   - `compiled_shaders.get("<name>")` for the externs path
   - `examples/<name>_fs_bundle.zig` for the bundle root
   - target name `sw-<name>-pipeline`
   - exe name `sw_<name>_pipeline`

3. Create `examples/sw_<name>_pipeline.zig`. Copy
   `sw_mandelbrot_pipeline.zig` verbatim, then swap:
   - `mandelbrot_fs_bundle` → `<name>_fs_bundle`
   - the Ubo literal in step 3 → schema-specific fields

4. Run `zig build sw-<name>-pipeline`. PNG appears in working dir.

### B. Browser side (Mode 5)

1. Add `"<name>_fs"` to the `wgpu_demo_shaders` list in `build.zig`
   (so wgpu_demo can `@embedFile("<name>_fs.wgsl")` and import the io).

2. In `examples/wgpu_demo/wgpu_demo.zig`:
   - Import the io: `const <name>_fs_io = @import("<name>_fs_io.zig");`
   - Define schema: `const <Name>Schema = struct { pub const Ubo = <name>_fs_io.Ubo; };`
   - Add State field: `<name>_shader: z.shader.LoadedShader(<Name>Schema) = undefined,`
   - Add loadShader call in `main()`:
     ```zig
     s.<name>_shader = try z.shader.loadShader(<Name>Schema, .{
         .f = &s.gpu_frame, .gpa = gpa,
         .vs_wgsl_source = @embedFile("default_shapes_vs.wgsl"),
         .fs_wgsl_source = @embedFile("<name>_fs.wgsl"),
         .label = "wgpu_<name>",
     });
     ```
   - Add per-frame Ubo push in `update()`:
     ```zig
     s.<name>_shader.pushUbo(f.queue, .{ ... });
     ```
   - Add draw block in `update()`:
     ```zig
     s.<name>_shader.bindForDraw(&ps);
     Backend.drawQuadBatched(&ps, .{ .x = X, .y = Y, .w = W, .h = H,
         .uv_x = 0, .uv_y = 0, .uv_w = 1, .uv_h = 1,
         .color = .{ 255, 255, 255, 255 } });
     Backend.flushBatch(&ps);
     ```

3. Run `zig build wgpu-smoke`. Bridge-calls/frame goes up by ~3-4 per new
   pipeline drawn; wasm size by ~10-20KB.

### Total time
~30 minutes per fractal, ~half browser, half native.

---

## Recipe 2: Texture-using FS (Samplers + maybe Ubo)

Examples: `shader_chroma_fs`, `shader_uniforms_fs` (TODO).

### Prerequisites already in place (this session)

`LoadedShader.setMaterial(tex_view, sampler)` exists. Comptime-checked via
`has_samplers`. Builds a fresh bind group with Ubo (binding 0, if present) +
texture view (binding 1) + sampler (binding 2). Convention matches
`autoMaterialBindGroupLayout`.

### Schema gotchas

`shader_chroma_fs_io.zig` has `Uniforms` (not `Ubo`). To use through
`loadShader`, define a Schema wrapper that exposes a `Ubo` matching the
Uniforms layout:

```zig
const ChromaSchema = struct {
    pub const Ubo = extern struct {
        col_diffuse: @Vector(4, f32),
        u_offset: f32,
        u_time: f32,
        _pad0: f32 = 0,
        _pad1: f32 = 0,
    };
    pub const Samplers = struct {
        texture0: u32, // marker; introspection only counts fields
    };
};
```

Alternative (cleaner long-term): teach `autoMaterialBindGroupLayout` to read
`Uniforms` as a UBO when present. For now the schema wrapper works.

### Steps (Track A — browser side, native deferred)

1. Add `"shader_chroma_fs"` to `wgpu_demo_shaders` in build.zig (already done
   this session).
2. Define `ChromaSchema` (as above) at the top of `wgpu_demo.zig`.
3. Add `chroma_shader: z.shader.LoadedShader(ChromaSchema)` to State.
4. Add `loadShader` call in `main()`.
5. **Create a texture to feed it.** Either use the existing
   `s.checker_texture` (`WgpuTexture.createCheckerboard`) or load a real
   image. Bind it via:
   ```zig
   try s.chroma_shader.setMaterial(s.checker_texture.view, s.checker_texture.sampler);
   ```
6. Per-frame: `s.chroma_shader.pushUbo(f.queue, .{ .col_diffuse = .{1,1,1,1},
   .u_offset = 0.02, .u_time = t });`
7. Per-frame draw: same `bindForDraw` + `drawQuadBatched` + `flushBatch`
   pattern as fractals.

### Open risk

The chroma WGSL output from spv2wgsl declares bindings — verify they match
the BG layout `loadShader` builds. If WGSL has texture at binding 1, sampler
at 2 (matching `autoMaterialBindGroupLayout`), it works. If not, need
spv2wgsl flags or schema rebinding.

### Native side (Mode 3)

Same bundle pattern as fractals, plus a TextureRef for the sampler. See how
`sw_engine_shader.zig` builds a 1×1 white texture and assigns to
`_texture0`. For real-image chroma, decode a PNG via `codecs.png.decode`
and pass to TextureRef.

---

## Recipe 3: Custom VS + 3D geometry (cube_split-style)

Not attempted yet. Architectural deltas:

- VS isn't `default_shapes_vs` — example owns its own VS pair, so the
  bundle module is bigger
- Vertex layout differs (position3 + uv + normal, not position2 + uv +
  color8). Need to extend `loadShader`'s default_vertex_layout — currently
  hard-coded to the 20-byte engine vertex.
- Depth buffer required → `desc.depth_state` must be set, requires
  `GpuFrame.depth_format` to be non-null.
- Per-vertex draws don't fit `drawQuadBatched` — need a raw
  `setVertexBuffer + drawIndexed` path.

Estimate: 2-3 sessions of careful work. Wait until texture path lands.

---

## Phase F backlog summary

Ports done:
- Mandelbrot (native + browser)
- Julia (native + browser)
- Mandel-Julia (native + browser)

Ports unblocked by Recipe 2:
- `shader_chroma_fs` — uses `setMaterial`
- `shader_uniforms_fs` — uniform-heavy variant

Ports blocked on Recipe 3:
- `cube_split` — custom VS + 3D vertex layout
- ~20 other 3D-using examples after that

2D-only examples (143 of them) that don't use a custom shader at all just
need to migrate from `drawing.zig` calls to the `Backend.drawQuadBatched`
+ `Renderer2D` pattern from `wgpu_demo.zig`. No new pipelines needed; pure
mechanical port.

---

## Patterns now formal

1. **Bundle modules**: 5-6 lines per shader that needs native compile.
2. **`loadShader` + `pushUbo` + `bindForDraw`**: 3-call browser recipe per pipeline.
3. **`setMaterial(view, sampler)`**: shipped this session for texture FS.
4. **`autoConnect` + `rasterizeTriangles`**: native dispatch through any IoT FS.
5. **`compiled_shaders.get(name)` → externs path → externs module**: build wiring.

Each pattern is documented in code + this doc. Bulk porting is now mechanical.
