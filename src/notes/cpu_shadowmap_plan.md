# CPU shadow-map pipeline — mirroring the WebGPU two-pass shadow map in software

> Status: **investigation / design.** Goal: reproduce, on the software
> rasteriser, exactly what the WebGPU backend does across two render passes for
> the shadow-map demo (`examples/shadowmap/shadowmap.zig`) — same `shaderMain`
> pair, same pass structure, same conventions — so the CPU path is both a
> teaching device and a ground-truth **oracle** for the GPU path (see
> `software_rasterizer_oracle.md`, whose scope stops at single-pass shader
> parity; this note adds the multi-pass / render-target layer on top).

## 1. The GPU pipeline we are mirroring

From `shadowmap.zig`, one frame is two WebGPU passes:

**Pass 1 — depth from the light (into an offscreen render target).**
`beginTextureModeRaw(rt)` opens a pass whose color attachment is an
`rgba16_float` RTT and whose depth attachment is `depth24_plus`. The depth
pipeline (position-only vertex layout, cull `.none`) runs `depth_vs` /`depth_fs`
which write the light-space NDC depth into the red channel. `mvp = light_vp *
model`. Result: the RTT's red channel is the shadow map.

**Pass 2 — camera view sampling the shadow map (into the backbuffer).**
The `lit_shadow` pipeline (position+normal layout, depth-tested) runs
`lit_shadow_vs` / `lit_shadow_fs`. Bind groups: group 0 = VS UBO `{mvp,
light_vp, normal_matrix}`, group 1 = the shadow-map sampler (the pass-1 RTT),
group 2 = FS UBO `{light_dir, base_color}`. The FS projects the fragment into
light space, `proj = clip*0.5+0.5`, flips `proj.y = 1 - proj.y` (WebGPU RTT
y-flip), samples `shadow_map(proj.xy)[0]` once, and compares
`current - bias > closest` → in shadow.

So the CPU must be able to: (a) render an indexed mesh through a VS/FS pair into
an **offscreen float render target** with depth, then (b) render the same mesh
from another camera into a second target while **sampling the first target's
texture** inside the FS. Both stages run the *same* four shader sources the GPU
compiles.

## 2. What the software rasteriser already has (the ~90%)

Inventory (files/lines are current):

- **Programmable VS+FS triangle pipeline** — `raster_shader.dispatchVertexShader`
  (runs `shaderMain` as a VS over an indexed mesh) + `raster_shader.rasterizeTriangles`
  (edge-function raster, perspective-correct interpolation of the whole `Out`
  struct, near-plane clip). Same `shaderMain(io) Out` source as the GPU. This is
  exactly a `drawIndexed`.
- **Depth test/write, cull, blend** — `RasterizeOpts{ front_face, depth_test,
  blend }`. Depth is `.less`, write-on-pass, NDC-z in the **wgpu [0,1] range**,
  `front_face=.ccw` = wgpu convention (raster_shader.zig:272). `rasterizeWithRuntimeOpts`
  maps runtime flags → the comptime opts.
- **Render targets** — `raster.Context` has up to 8 framebuffers
  (`genFramebuffers`), 128 textures, `framebufferTexture2D` to attach a texture
  as a color attachment (raster.zig:607). `rasterizeTriangles` writes color to
  `ctx.colorBufferBytesMut()` and depth to `ctx.depthBufferBytesMut()` — i.e. to
  the **currently bound framebuffer** (raster_shader.zig:546). Binding an
  offscreen FBO redirects both. This is a `beginRenderPass`.
- **Float color formats** — `color_r32`, `color_r16`, `color_r16g16b16a16`,
  `color_r32g32b32a32` already exist (raster_pixel.zig:41-46). The GPU shadow map
  is depth-in-red `rgba16_float`; the CPU equivalent is a `color_r32` (or
  `color_r16`) target — same "depth stored as a float color" trick, so **no new
  format and no depth-texture-sampling path is required**.
- **Texture sampling in the FS** — `rasterizeTriangles` samples `_texture0` at
  runtime (raster_shader.zig:796); the FS's `Sampler2D` callable is backed by the
  bound texture via the pixel `ReadColorFn` table. `bindTexture` sets it.
- **Comptime raster** — `rasterizeToImage` rasterises the same VS/FS pair with an
  internal z-buffer at comptime (bakes the side-by-side corners). A shadow map is
  two dependent passes, so the *corner* would bake only the lit pass over a
  comptime-baked shadow map — possible but secondary.

## 3. The gaps (narrow)

1. **Bind a render target's texture as the next pass's sampler.** The mechanics
   exist (`framebufferTexture2D` to render into a texture; `bindTexture` to sample
   it) but nothing yet routes the FS's *named* sampler (`io_in.shadow_map`) to a
   chosen texture. For the shadow map there is exactly **one** sampler, so
   `shadow_map → _texture0` is a direct binding; multi-sampler (PBR albedo +
   metalness + …) is a later generalisation, not needed here.
2. **A float color target must be write- and read-able.** `color_r32` has a read
   codec (raster_pixel.zig:393); **verify it is also in `write_color_table`** (the
   FS writer path) and add the 4-byte f32 writer/reader if missing. Small, local,
   and independently testable.
3. **A pass-shaped orchestration API.** The primitives above are GL-flavoured
   (bind FBO, set flags, dispatch, rasterise). To *teach* the WebGPU model we want
   the CPU frame to read like the GPU frame — a thin façade (§4) over the existing
   calls. No new rendering capability; pure ergonomics + fidelity framing.
4. **Convention parity (oracle-critical).** The shadow projection's
   `proj.y = 1 - proj.y` flip exists because the GPU RTT is sampled with a
   top-left origin. The CPU shadow map is stored in the raster context's own row
   order; the FS is the *same source*, so the CPU must store/sample the shadow map
   with the **same orientation** the flip assumes, or the flip must be a shared
   host-side convention both targets inherit. Same for NDC-z [0,1] (already the
   raster convention) and the sample position (texel-center). Getting these bit-
   comparable is the whole point of the oracle.

## 4. Proposed API — a pass-shaped CPU layer

A thin module (`src/raster_pass.zig`, ~exported as `z.cpu_pass.*`) that mirrors
the WebGPU calls 1:1, over the existing `raster.Context` + `raster_shader`:

```
// ---- GPU (today) ----            // ---- CPU (proposed) ----
beginTextureModeRaw(rt, clear)      cpuBeginPass(ctx, .{ .color=shadow_fb,
setPipeline(depth_pipeline)                              .depth=shadow_fb,
setBindGroup(0, depth_ubo)                              .clear=... })
drawIndexed(mesh)                   cpuSetPipeline(.{ .cull=.none,
endTextureModeRaw()                                  .depth_test=true })
                                    cpuSetBindGroup(0, &io, depth_ubo)
                                    cpuDrawIndexed(DepthVs, DepthFs, mesh)
                                    cpuEndPass(ctx)
```

Where:

- `cpuBeginPass(ctx, targets)` = `bindFramebuffer` + `clearColor/clearDepth` +
  `clear`. `targets.color` is a float FBO for pass 1, the screen FBO for pass 2.
- `cpuSetPipeline(opts)` stashes `RasterizeOpts` (cull/depth/blend) for the draw.
- `cpuSetBindGroup(n, &base_io, ubo)` writes the UBO into `base_io.u` (group 0/2)
  or `cpuBindSampledTarget(&base_io, .shadow_map, shadow_fb.colorTexture())`
  (group 1) — the latter is gap #1's one line.
- `cpuDrawIndexed(Vs, Fs, mesh)` = `dispatchVertexShader(Vs, …)` then
  `rasterizeWithRuntimeOpts(Vs, Fs, ctx, outs, idx, base_io, connect, depth,
  blend, cull)`.

The two shadow passes then become ~20 lines that structurally match
`shadowmap.zig`, running `depth_vs/_fs` and `lit_shadow_vs/_fs` **unchanged**.

## 5. The payoff demo — the real "side-by-side shadow map"

`examples/shadowmap_cpu_gpu/…`: split screen, **left = the WebGPU two-pass
shadow map, right = the CPU two-pass shadow map**, same four shaders, same
light + camera UBO. Unlike the ray-traced `shadow_sidebyside` (which fits the
one-shader-three-ways pattern), this is the honest shadow-**mapping** comparison:
two real passes on each side, the CPU render target standing in for the GPU RTT.
Because both evaluate the identical `shaderMain` sources, a per-pixel diff of the
two halves is the oracle test — any `spv2wgsl`/Tint discrepancy shows up as a
visible seam at the splitter.

## 6. Build order & effort

1. **Codec**: ensure `color_r32` read+write codecs (gap #2). Tiny; unit-test in
   isolation.  ~½ day.
2. **Sampler routing**: bind an FBO's color texture as the FS sampler
   (`cpuBindSampledTarget`, single-sampler shadow_map→_texture0). Verify sampling
   a `color_r32` texture returns the stored f32 in `.r`.  ~½ day.
3. **Pass façade** (`raster_pass.zig`): the §4 wrappers. Pure sugar over existing
   calls.  ~1 day.
4. **CPU shadow map** using the real `depth_*` + `lit_shadow_*` shaders into an
   `r32` FBO, then the screen. Nail the y-flip/NDC/sample-center parity (§4.4)
   against the GPU output.  ~1–2 days (parity is the work, not the rendering).
5. **Side-by-side demo** (§5) + a diff overlay.  ~1 day.

Risk is concentrated entirely in step 4 (convention parity), which is exactly the
oracle's reason to exist. Everything else is wiring over machinery that already
ships. No GPU-backend change is required; this is additive on the CPU side.
