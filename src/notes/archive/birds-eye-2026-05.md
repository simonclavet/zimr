# Birds-eye review — May 2026

Reading: webgpu-migration-plan.md + the wgpu stack source (16 modules,
~6300 LOC) + raygpu (`include/raygpu.h`, 2010 LOC) + mach
(`src/sysgpu/`, `src/gpu.zig`, `examples/core-triangle/`).

---

## §1.  The three philosophies side by side

**raygpu** — everything implicit.  `BeginDrawing()` flips global
`g_renderstate`; `DrawRectangle()` reads it; user never touches
`WGPUDevice`, `WGPURenderPassEncoder`, or `WGPUCommandEncoder`.
Excellent for "hello world," terrible for control.  When you need a
compute pass or a render-bundle, you fight the abstraction.

**mach** — everything explicit.  `device.createRenderPipeline(...)`,
`encoder.beginRenderPass(...)`, `pass.setPipeline(...)`,
`pass.draw(...)`, `pass.end()`, `encoder.finish()`,
`queue.submit(...)`.  Every object is a `*gpu.X` the user holds.
Excellent control, ~50 lines for a triangle.  No magic.

**zimr today** — half-and-half.  `GpuFrame` holds the long-lived
state (`device`, `queue`, `surface`, `pipeline_cache`) AND the
per-frame transients (`encoder`, `surface_view`) AND a hidden state
machine (`current_pass`, `current_pipeline`, `current_bind_groups`,
`matrix_stack`, `shapes_batch`, `pending_clear`).  User code does
`Backend.beginRenderPass(f, desc)` and the resulting pass goes into
`f.current_pass`.  User code reads `f.current_pass.?` to bypass the
abstraction.

The mixed model has a real cost: the state-machine fields are the
"hidden globals" Simon's "no hidden state" instinct points at.  They
*look* explicit (you can see them on the struct) but they FUNCTION as
implicit (a `Backend.X` call mutates them without an explicit return).

## §2.  What "be more like mach" means concretely

Three sharp moves toward mach, keeping selective raygpu sugar:

**A — Return handles, don't stash them.**  `beginRenderPass` should
return a `RenderPass` value.  `beginComputePass` returns `ComputePass`.
The user assigns the result to a local; passes it explicitly to draw
helpers; calls `pass.end()` when done.  No `f.current_pass`.

**B — Encoder is a value the user owns.**  `beginFrame` returns a
`CommandEncoder` (or it lives in the user's State).  Passes are
created from the encoder, explicitly.  `endFrame` becomes
`encoder.finish() + queue.submit()`.

**C — Convenience helpers take the pass, not the frame.**
`drawQuadBatched(pass, batch, desc)`, `drawTriangleBatched(pass,
batch, desc)`.  The batch is the user's; the pass is the user's; no
hidden bookkeeping.

What stays raygpu-flavored (deliberately): the matrix-stack
`pushMatrix/popMatrix/translate/rotate/scale` API + the `Renderer2D`
batched drawing layer.  These are real ergonomic wins for the
target audience (hobby game/graphics devs) and they're scoped — the
matrix stack lives on the user's `Renderer2D`, not on a global.

## §3.  What the 16 wgpu modules say about the seams

Sizes (LOC):

```
spv2wgsl.zig          2194   the translator (build-time only after F)
wgpu.zig               665   typed handles + JS bridge
shader_runtime_wgpu    460   loadShader(SchemaT, desc) — high value
gpu_iface.zig          366   pass-based trait, both backends
shader_introspect      346   comptime UBO + BGL introspection
renderer_2d.zig        308   raylib-parity drawing layer
descriptor_encoder     300   wasm/JS binary serialization
wgpu_texture.zig       292   WgpuTexture + WgpuRenderTexture
shader_compile.zig     266   CompiledShader (Phase D will shrink this)
render_pass.zig        263   pass lifecycle wrapper
gpu_frame.zig          238   GpuFrame state container ← the hidden-state struct
pipeline_cache.zig     196
default_shaders.zig    186   hand-written WGSL — TO BE DELETED in C4
storage_buffer.zig     166
bind_group_cache.zig   155
compute_pass.zig        75
```

Two thirds of the surface is in the bottom half (each module under
350 LOC).  The leverage points are:

- `gpu_iface.zig` — the trait choice.  Today it bakes the
  hidden-state model into the API shape.  Refactoring this is
  high-value: it shifts the WHOLE stack toward mach.
- `gpu_frame.zig` — the state-machine fields.  Removing them
  forces every caller to be explicit.  Hard to do incrementally
  because every site reads `f.current_pass`; an arc, not a
  five-minute change.
- `shader_runtime_wgpu.zig` — `loadShader(SchemaT, desc)` is
  already great.  Phase D just deletes the WGSL-source fallback.
- `default_shaders.zig` — pure deletion target.

## §4.  Best 10 next steps (ranked)

These are sized for one session each unless noted.  Listed in roughly
the order they pay back — but every one of them is independently
useful, so re-order to taste.

### 1.  Pipeline takes two shader modules (Phase C3 unblocker)

`createRenderPipeline(device, layout, vs_module, fs_module,
vs_entry, fs_entry, descriptor, label)`.  Today it takes ONE module
+ vs_entry + fs_entry strings; the engine's typed pipeline emits
two separate WGSL files each with `fn entry`.  Splitting unblocks
Phase C3 (Renderer2D.init uses the engine output) without hacks.
~1 session.  Files: `src/wgpu.zig`, `src/descriptor_encoder.zig`,
`src/web/zimr_wgpu.ts` JS bridge, every caller.

### 2.  Phase C3+C4: Renderer2D consumes engine WGSL, delete default_shaders.zig

After (1).  `Renderer2D.init` swaps `compileFromWgsl(SHAPES_COMBINED_SOURCE)`
for `@embedFile("default_shapes_vs.wgsl") + @embedFile("default_shapes_fs.wgsl")`.
Material bind group moves from binding 1,2 within group 1 to binding 0,1
within group 1 (matching the `--sampler-group=1` output already shipped).
Delete `default_shaders.zig`.  Rule 1 of the plan satisfied.

### 3.  Make passes return values, not stash into GpuFrame

The big architecture move toward mach.  `WgpuBackend.beginRenderPass`
returns `wgpu.RenderPassEncoderHandle`.  `drawQuadBatched` etc. take
`pass: wgpu.RenderPassEncoderHandle` instead of reading
`f.current_pass`.  Delete `current_pass`, `current_compute_pass`,
`current_pipeline`, `current_bind_groups`, `active_render_target` from
`GpuFrame`.  The user writes:

```zig
const pass = z.beginRenderPass(&encoder, .{ .color_view = …, .clear = … });
defer pass.end();
z.drawQuadBatched(pass, &batch, …);
z.flushBatch(pass, &batch);
```

Mechanical sweep, ~1-2 sessions.  Pays back forever — every future
example, every doc, every error message is clearer.  Probably also
shrinks `gpu_iface.zig` by 20-30%.

### 4.  Phase D: one shader API — delete `loadShaderFromWgsl`

After Rule 1 (no hand WGSL), the only path is `loadShader(SchemaT,
desc)`.  `DynamicLoadedShader` + `loadShaderFromWgsl` come out.
`ShaderDesc.SourceKind` enum collapses to one variant.  ~150 LOC
deletion plus call-site fixes.  Clean victory.

### 5.  Phase E: SwBackend dispatches through `rlsw_shader.dispatchFragmentShader`

The software-renderer path is currently a stub.  Wire the SwBackend
to invoke fragment shaders per-pixel via the existing
`src/rlsw_shader.zig::dispatchFragmentShader` — same Zig source, no
GPU.  Bonus: `examples/wgpu_demo_split.zig` showing left half rendered
on GPU, right half on CPU with PIXEL PARITY.  This is the rule-5
demonstration that closes the loop on "shaders work everywhere."

### 6.  Move matrix_stack + shapes_batch off GpuFrame onto Renderer2D

Today they're fields on `GpuFrame` — every backend pays for them
even when not drawing 2D.  Move them to `Renderer2D` where they
belong; the user owns the `Renderer2D` already.  Independent of (3)
but composes well with it.  ~1 session.  Forces every
`pushMatrix`/`drawCircleV` call to thread through `&renderer`
explicitly — more verbose call sites but radically clearer ownership.

### 7.  DSL marker for `@group(N) @binding(M)` in Zig shader IO

Today `--sampler-group=N` is a build-pipeline flag.  Real fix: encode
the group hint in the Zig schema.

```zig
pub const Samplers = struct {
    albedo: shader.Sampler2D(.albedo, .{ .group = 1, .binding = 0 }),
};
```

`shader_introspect.zig` reads the hint; `gen_shader_externs` emits
explicit `@spv("OpDecorate DescriptorSet N")`-equivalent; the
zspv rewriter respects what's already there.  Removes the need for
build-pipeline magic.  Lets future engine shaders pick their own
groups (shadow maps at group 2, etc.).  ~1-2 sessions.

### 8.  `wgpu_demo_split.zig` (rule 5 demonstration)

Concrete example: same Zig fragment shader, dispatched on GPU on
the left half of the canvas and on CPU on the right half, with a
pixel-diff overlay showing zero difference.  This is the "you wrote
one shader and it runs everywhere" headline screenshot.  Depends
on (5).  ~1 session of polish + a blog post in waiting.

### 9.  Decide on the prefix question + rename atomically

The plan has a parked Q: `wgpu_*` (current) vs `rlwgpu_*` vs `gl3_*`
once wgpu becomes the default.  Decide.  My recommendation: drop the
prefix on the engine surface (just `gpu_frame.zig`, `gpu.zig`,
`renderer_2d.zig`) and prefix the GL-backend stragglers `gl_*` until
Phase F deletes them.  One atomic sweep, then the names match the
post-F state.  ~1 session of grep + sed.

### 10.  Vendor SPIRV-Headers grammar JSON into `tools/spirv/`

The parked Q1 from the plan.  ~50KB of JSON + a one-time generator
script that translates it into `tools/spirv/opcodes.zig` (typed Op
enum + operand-kind metadata).  Replaces the hand-maintained constants
in `tools/zspv_rewrite.zig` (`op_decorate = 71`, etc.).  Removes a
class of "wait what opcode is that" bugs and unlocks better
diagnostics in spv2wgsl ("OpFoo at offset N expected 3 operands, got
2").  Self-contained, no architectural risk.

---

## §5.  Ordering and dependencies

```
1 ── 2 ── (Phase C done, default_shaders.zig deleted)
3 ── 6 ── (state-machine purge, no hidden globals)
4    (Phase D, trivial after C)
5 ── 8   (rule 5 demo)
7    (DSL marker — replaces the --sampler-group flag long-term)
9    (cosmetic + future-proofing)
10   (tooling foundation, anytime)
```

Critical path for "shipping wgpu as the default": 1 → 2 → 3 → 4 → 5.
Aspirational big win: 8 (the rule 5 demo screenshot).

## §6.  What this is NOT proposing

- Deleting the GL path right now.  That's Phase F; it depends on
  the wgpu side being functionally complete first.  All 10 steps
  above keep GL working.
- Reducing zimr to mach's verbosity.  Steps 3 + 6 strip the hidden
  state machine but keep `Renderer2D` and `pushMatrix`/`drawCircleV`
  — the raygpu-style sugar that makes zimr fun.
- Building a sysgpu-style cross-backend abstraction (mach supports
  d3d12 + metal + vulkan + opengl behind one API).  zimr's targets
  are WebGL2 (today) and WebGPU (after F) — only one ships at a
  time.  The trait in `gpu_iface.zig` is enough; sysgpu's
  `Interface(struct { ... })` pattern is overkill for our scope.
- Touching `spv2wgsl.zig`.  It's the second-largest file in the
  stack (2194 LOC) and it's working.  Polish later, don't refactor
  now.

## §7.  TL;DR

Three architectural shifts unlock everything else:

1. **Return values, not stashed state** (step 3).  Mach's discipline,
   zimr's flavor.
2. **One shader path** (step 4).  Rule 1 + Rule 2 of the plan, real.
3. **Engine shaders use the typed pipeline** (steps 1+2).  Closes
   the loop on "no hand-written WGSL."

After those three, the rest is iteration on a clean foundation.
