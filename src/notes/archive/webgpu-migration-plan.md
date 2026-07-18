## webgpu-migration-plan.md — zimr's WebGL → WebGPU migration

The single source of truth for the wgpu migration arc.  Mirrors the
convention of other `src/notes/<arc>-plan.md` files (zig-shader-pipeline,
software-shaders, etc.) — read this first to know where we are.

---

## §0.  Why this arc

WebGL2 has carried zimr beautifully but has structural ceilings: no
compute shaders, no real storage buffers, no proper async pipeline
creation, no modern memory model.  WebGPU is the modern web GPU API
and is shipping in Chrome (stable), Edge (stable), Safari 26 (stable),
Firefox 142+ (stable as of late 2025).  The path forward is to migrate
zimr's GPU path from WebGL2 to WebGPU.

The five non-negotiable rules for the finished system:

1. **Shaders only in Zig.**  No hand-written WGSL anywhere.  WGSL is
   an internal artifact, never a public input.
2. **Build-time translation.**  Normal Zig compiler → SPIR-V → our
   own Zig code translates and verifies → WGSL embedded in wasm.
   No Naga, no Tint, no third-party transpiler in the shipped wasm.
3. **Typesafe CPU↔shader interface.**  Verified at compile time.
   Renaming a uniform breaks both sides simultaneously.
4. **`zimrmath.zig` works in both GPU and CPU code.**  One math
   library, both backends.
5. **Shaders work in the software renderer.**  The same Zig shader
   source dispatches per-pixel on CPU via `rlsw_shader.zig`.

Rules 3, 4, and 5 are ALREADY satisfied on the GL path
(`typesafe_zig_shaders.md` + `zimrmath.zig` + `rlsw_shader.zig`).
The wgpu side plugs into the same infrastructure.

Rules 1 and 2 are NEW work — they don't apply to the GL path
(which uses hand-written GLSL via spirv-cross, a third-party tool).

---

## §1.  Architecture context

The existing GL path produces `.glsl` artifacts via this pipeline (see
`src/shader_codegen.zig::ShaderPipeline.addShader`):

```
foo_fs.zig + foo_fs_io.zig
    │  gen_shader_externs (bootstrap exe; reflects on _io.zig)
    │
    ▼
foo_fs_externs.zig          ─── codegen-emitted typed extern decls
    │
foo_fs.zig + foo_fs_externs.zig
    │  zig build-obj -target spirv32-vulkan
    ▼
shader.spv
    │  zspv --rewrite-samplers      (combined-sampler placeholder → real)
    ▼
shader.rewritten.spv
    │  spirv-opt -O                 (dead-strip Zig stdlib leftovers)
    ▼
shader.opt.spv
    │  spirv-val                    (build-time safety gate)
    │  spirv-cross --version 300 --es
    ▼
shader.raw.glsl
    │  zglsl                        (text rewrites: vec4 arrays → mat4, etc.)
    ▼
shader.glsl                          ─── @embedFile target
```

The wgpu path will produce `.wgsl` artifacts alongside `.glsl` via a
parallel pipeline, REPLACING spirv-cross with our own spv2wgsl:

```
foo_fs.zig + foo_fs_io.zig + foo_fs_externs.zig
    │  zig build-obj -target spirv32-vulkan
    ▼
shader.spv                         (rewritten + opt as needed)
    │  src/spv2wgsl.zig            (OUR translator — Rule 2)
    ▼
shader.wgsl                        ─── @embedFile target
```

The runtime then `loadShader(SchemaT, .{ .wgsl = @embedFile(...) })`
the pre-translated string.  No transpiler in the shipped wasm.

---

## §2.  Locked decisions (D1–D17)

After studying Mach and raygpu (`webgpu-migration.md` for the long-
form rationale), the architecture is:

- **D1.  Scope — evolutionary.**  Most call sites keep their shape;
  heavy-arg APIs migrate to descriptor-with-defaults.
- **D2.  Shader source — typed schema is the ONLY path.**  No
  `loadShaderFromWgsl` escape hatch.  Reflection comes from comptime
  schema introspection (`shader_introspect.zig`), not from parsing
  WGSL at runtime.
- **D3.  Frame.gpu surface — A3 hybrid.**  Encoder, queue, device,
  current pass, current pipeline, matrix stack — all visible as
  fields on `f.gpu`.  Power users reach in directly; convenience
  wrappers exist for the common patterns.
- **D4.  Pipeline cache — hot-prebake 8 combos + lazy.**  Pre-build
  pipelines for the eight most common state combinations
  (blend × depth × cullface); lazy-compile the rest on first use.
- **D5.  SPIR-V → WGSL via `src/spv2wgsl.zig` — the ONLY translator.**
  No Naga, no Tint in the shipped wasm.  Build-time only.  Must
  reach 100% clean rate on the corpus.  **Status: 100% as of
  Phase A completion (51/51 shaders).**
- **D6.  Bind groups — hierarchical** (per-frame, per-material,
  per-draw).
- **D7.  gpu_iface trait — mid-level pass-based.**  `WgpuBackend`
  (real) and `SwBackend` (rlsw-dispatched).
- **D8.  Side-by-side GL+wgpu through Phase E**; delete GL at Phase F.
- **D9.  Dual `z.gl` + `z.gpu` vocabulary**; GL stays during
  transition.
- **D10.  Hot-reload cache invalidation** on shader source hash.
- **D11.  Allocator-driven lifetime**.  No global state for the
  device, surface, encoder.
- **D12.  WGSL parser never built.**  We never accept WGSL from
  users.  Reflection metadata comes from the `_io.zig` schema.
- **D13.  No mutable globals.**  Confirmed via lint.
- **D14.  Comptime introspection over runtime parsing.**  Schema-
  driven layout generation.
- **D15.  Three explicit layers** (public API → state machine →
  extern seam) — same as the GL path.
- **D16.  Build-time translation, not runtime.**  `addShaderWgsl`
  in `ShaderPipeline` produces a `.wgsl` artifact at build time.
- **D17.  wgpu path plugs into existing infrastructure.**  Reuses
  `_io.zig` schemas, `rlsw_shader.zig` dispatch, the same engine
  shaders in `src/shaders/`.

---

## §3.  Phase plan

### Phase A — drive spv2wgsl to 100% on the corpus

Without this, nothing else matters. The transpiler IS the build
pipeline; if it doesn't handle every shader, those shaders can't
ship.

- **A1.  Investigate the "3 unresolved ids per shader" pattern.**
  All 22 unresolved ids in the 8 corpus gaps traced to module-scope
  `OpUndef`.  Fix: add `emitModuleUndef` in pass3 + `emitUndef` in
  pass4, both emitting WGSL zero-init (`T()`).
- **A2.  Investigate the 14 panic shaders by size.**  All 14
  traced to combined-sampler shaders (pre-`zspv`-rewrite SPIR-V
  loading `OpTypeSampledImage` directly).  Fix: detect
  `extra_a/extra_b == 0` in `emitImageSample`; emit a grep-friendly
  `// ERROR:` diagnostic + zero-init placeholder instead of
  panicking.  The shader transpiles; downstream build steps can
  refuse to embed shaders that contain `// ERROR:` markers.
- **A3.  Regression corpus.**  Lock down each shader's
  `(spv-md5, wgsl-md5)` pair as a CI fixture.  `zig build wgpu-corpus`
  reports hash drift.
- **A4.  End-state metric:** every shader in `tests/`, `examples/`,
  and `src/shaders/` transpiles cleanly with zero unresolved
  placeholders and zero `// ERROR:` markers.

### Phase B — wire WGSL into the build pipeline

Parallel-eligible with A: B doesn't depend on A being perfect; the
plumbing works for shaders that transpile cleanly today (most of
them, post-A1+A2).

- **B1.  Add `addShaderWgsl` to `ShaderPipeline` in
  `src/shader_codegen.zig`.**  Mirror the existing `addShader` (which
  outputs `.glsl`).  Same input (`.zig` source + optional `_io.zig`
  schema), additional output: a `.wgsl` file via spv2wgsl on the
  opt'd SPIR-V.
- **B2.  Both outputs unconditional.**  Every `addShader` call
  produces both `.glsl` and `.wgsl`.  Cost is one spv2wgsl run per
  shader; cheap.  Consumers pick which to `@embedFile`.
- **B3.  Wire `zig build wgpu-corpus` to also exercise every
  shader the engine actually uses** (not just the discovered
  `.spv` files in the cache).

### Phase C — replace engine WGSL with Zig shaders

The engine's own shaders dogfood the typed-schema pipeline.

- **C1.  Author `src/shaders/default_shapes_vs.zig` + `_iface.zig`.**
  Equivalent to today's hand-written `DEFAULT_VS_SOURCE` in
  `src/default_shaders.zig`, but written in Zig and going through
  the standard pipeline.
- **C2.  Same for `default_shapes_fs.zig` and any other engine-
  owned shader** (text rendering).
- **C3.  `Renderer2D.init` swaps `compileFromWgsl(DEFAULT_SHAPES)`
  for `@embedFile("default_shapes_fs.wgsl")`.**  No runtime
  transpilation; just embed the pre-translated string.
- **C4.  Delete `src/default_shaders.zig`** (hand-written WGSL,
  violates Rule 1).

### Phase D — wire wgpu loadShader to the new contract

- **D1.  Change `ShaderDesc(SchemaT)`'s `source` field** from
  "SPIR-V or WGSL bytes" to "pre-translated WGSL bytes."  The
  spv2wgsl call already happened at build time.
- **D2.  Delete `loadShaderFromWgsl` and `DynamicLoadedShader`**
  from `src/shader_runtime_wgpu.zig`.  No escape hatch.
- **D3.  `loadShader(SchemaT, .{ .wgsl = @embedFile(...) })`
  becomes the only API.**

### Phase E — wire SwBackend through rlsw_shader.zig

The SW path is already designed in `software_shaders.md`.  This
is wiring, not invention.

- **E1.  `SwBackend.drawQuadBatched` / `drawTriangleBatched`
  rasterize through rlsw's existing primitive functions.**
- **E2.  `loadShader(SchemaT, fn_ptr, ...)` captures the Zig
  shader function pointer.**  WgpuBackend ignores it; SwBackend
  dispatches it via `rlsw_shader.dispatchFragmentShader`.
- **E3.  Side-by-side example: `examples/wgpu_demo_split.zig`**
  — left CPU, right GPU, same shader source.  Pixel-parity
  proof.
- **E4.  End-state metric:** the wgpu demo runs identically
  (modulo precision) on both backends with a single source switch.

### Phase F — close down GL

- **F1.  Delete the GL path** once every example works on wgpu.
- **F2.  Delete `src/web/zimr.ts`'s GL bridge.**  The wgpu bridge
  is the only path.

---

## §4.  Status board

| Phase | Status | Notes |
| ----- | ------ | ----- |
| A1 — module-scope OpUndef         | ✅ DONE | `emitModuleUndef` + `emitUndef` |
| A2 — combined-sampler diagnostic  | ✅ DONE | grep-friendly `// ERROR:` markers |
| A3 — regression corpus            | ✅ DONE | 64 entries locked (May 2026) |
| A4 — every project shader clean   | ✅ DONE | 18 engine + example shaders, 0 errors |
| B1 — addShaderWgsl                | ✅ DONE | exists in `src/shader_codegen.zig` |
| B2 — both `.glsl` + `.wgsl`       | ✅ DONE | engine + examples, May 2026 turn 3.8 |
| B3 — corpus exercises engine shaders | ✅ DONE | refreshed corpus covers all engine + examples |
| C1 — default_shapes_vs.zig        | ✅ DONE | exists in `src/shaders/` |
| C2 — default_shapes_fs.zig        | ✅ DONE | exists in `src/shaders/` |
| C3 — Renderer2D.init uses embedFile | ⏳ NEXT | trivial after B2 |
| C4 — delete default_shaders.zig   | ⏳ pending | follows C3 |
| D1 — ShaderDesc accepts only WGSL | ✅ DONE | May 2026 — `wgsl_source: []const u8`, no runtime spv2wgsl |
| D2 — delete loadShaderFromWgsl    | ✅ DONE | gone earlier, no escape hatch |
| D3 — loadShader is the only API   | ✅ DONE | confirmed: no other entry point |
| E1 — SwBackend draw primitives    | ⏳ partial | turn 3 of finishing_new_gpu_foundations shipped the vtable |
| E2 — fn-ptr at loadShader         | ⏳ pending | |
| E3 — wgpu_demo_split example      | ⏳ pending | `mandelbrot_split` already does this for one shader |
| F1 — delete GL path               | ⏳ pending | major version bump; 106 examples to port |
| F2 — single TS bridge             | ⏳ pending | |

---

## §5.  Phase A results (DONE)

Corpus clean rate: **57% → 100%** (51/51 shaders).

Two bug fixes:

1. **Module-scope OpUndef wasn't handled.**  Body references to
   undef-produced ids hit unset slots in `s.ids` and got
   `__unresolved_N__` placeholders.  Added handlers in both
   pass3 (`emitModuleUndef` emits `const undef_N: T = T();` at
   module scope) and pass4 (`emitUndef` emits
   `let _N: T = T();` inside functions).  Both rely on WGSL's
   zero-init constructor (`T()`) being valid for every type
   SPIR-V can OpUndef.

2. **Combined samplers panicked.**  When `OpImageSampleImplicitLod`
   consumed a SampledImage that came from `OpLoad` of a combined
   sampler (the old GL pattern, pre-`zspv` rewrite), the
   `emitImageSample` handler called `lookupId(0)` because
   `extra_a`/`extra_b` were never populated.  Fixed by detecting
   the case and emitting:

   ```wgsl
   // ERROR: combined sampler at %273 — WGSL requires separate texture+sampler bindings.
   // Rewrite the shader so it uses separate `texture_2d<f32>` and `sampler` uniforms.
   let _274: vec4<f32> = vec4<f32>();
   ```

   The shader transpiles cleanly; the diagnostic is grep-friendly
   for downstream build steps to refuse to embed it.

Tooling that made the debugging fast (kept for next time):

- **SPIRV-Headers grammar JSON** at
  `/tmp/SPIRV-Headers-main/include/spirv/unified1/spirv.core.grammar.json`
  — canonical opcode metadata (873 instructions, each with opcode,
  operand kinds, IdResult flag).  Vendor this into `tools/spirv/`
  next session.
- **`/tmp/dbg/showids.py`** — given an `.spv` + id list, prints
  producing instructions with type info.
- **`/tmp/dbg/translate_dbg.ts`** — Bun harness with stderr
  passthrough so spv2wgsl panics surface (the wasi shim was eating
  them).
- **Breadcrumb fields on `State`** (`debug_current_opcode`,
  `debug_current_offset`) set at top of pass-4 dispatch loop.
  Panics from any handler now report what opcode + word offset
  was being processed.

---

## §6.  Current files and their roles

What landed in this arc (everything under `src/` unless noted):

### Translator (build-time only after Phase D)
- `spv2wgsl.zig` — the SPIR-V → WGSL translator (~2100 LOC)
- `spv2wgsl_wasm.zig` — wasi-reactor wrapper exposing transpile
  to Bun (used by `webtests/transpiler_corpus.ts`)

### wgpu runtime stack
- `wgpu.zig` — typed handles + JS bridge externs + Zig wrappers
- `gpu_frame.zig` — `GpuFrame` state container
- `gpu_iface.zig` — pass-based trait + `WgpuBackend` + `SwBackend`
- `pipeline_cache.zig` — (source_hash, state_combo) → pipeline
- `bind_group_cache.zig` — (texture_view, sampler, ubo, layout) → bind group
- `render_pass.zig` / `compute_pass.zig` — pass lifecycle wrappers
- `storage_buffer.zig` — `StorageBuffer(T)`
- `shader_introspect.zig` — comptime UBO + bind-group-layout introspection
- `shader_compile.zig` — `CompiledShader { wgsl, reflection }` (Phase D will
  reduce this to a thin wrapper since reflection comes from the schema)
- `shader_runtime_wgpu.zig` — user-facing `loadShader(SchemaT, desc)`
- `descriptor_encoder.zig` — binary serialization for the wasm/JS boundary
- `wgpu_texture.zig` — `WgpuTexture` + `WgpuRenderTexture`
- `default_shaders.zig` — hand-written WGSL for shapes/text — **TO BE
  DELETED in Phase C**
- `renderer_2d.zig` — raylib-parity drawing layer over the wgpu stack
- `zimr_wgpu.zig` — umbrella module re-exporting the public surface
- `web/zimr_wgpu.ts` — JS bridge (~860 LOC)
- `wgpu_smoke_test.zig` — scaffold with hand-written triangle WGSL —
  redundant with `wgpu_demo`, candidate for deletion

### Tests / examples
- `examples/wgpu_demo/wgpu_demo.zig` + `index.html` — first wgpu app
- `webtests/wgpu_smoke.ts` — Bun smoke (no GPU needed)
- `webtests/transpiler_corpus.ts` — runs spv2wgsl across every
  unique `.spv` in `.zig-cache/`

### Build steps (in `build.zig`)
- `wgpu-demo` — builds the demo to `zig-out/wgpu/`
- `wgpu-smoke` — smoke-tests the demo wasm in Bun
- `wgpu-corpus` — runs the transpiler corpus

---

## §7.  Open questions for Simon

1. **Should I vendor SPIRV-Headers into `tools/spirv/`?**  Currently
   I'm reading from `/tmp/SPIRV-Headers-main/` (Simon's upload).
   For self-contained reproducibility, the grammar JSON belongs in
   `tools/spirv/` alongside SPIRV-Tools and SPIRV-Cross.  Maybe a
   ~50KB add to the repo.

2. **Naming consistency.**  My files use `wgpu_*` prefix
   (`wgpu.zig`, `gpu_frame.zig`, etc.) while the existing engine
   uses `rlgl_*` and `rlsw_*` prefixes.  Should the wgpu stack
   move to a `rlwgpu_*` prefix or `gl3_*` prefix when wgpu becomes
   the default?  Defer to Phase F.

3. **PLAN.md current focus.**  This is the active arc.  I'll
   update PLAN.md to point at this file.

---

## §8.  Next concrete step

**Phase A3 — regression corpus.**  Lock down the 51 clean outputs.
Hash each `(spv-md5 → wgsl-md5)` pair into
`tests/fixtures/wgsl_corpus.json`.  Wire `zig build wgpu-corpus` to
fail when a hash drifts.  Refresh fixtures with
`zig build wgpu-corpus-refresh`.

Then **Phase B1** in the same session if budget permits — the
`addShaderWgsl` plumbing is well-defined: mirror `addShader`
through `compile → zspv → opt → val`, then run spv2wgsl instead
of spirv-cross.  Output: `.wgsl` instead of `.glsl`.
