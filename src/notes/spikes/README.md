# @SpirvType image-op spikes — P0 SOLVED

These two files prove the operation that blocked the whole no-inline-WGSL arc:
**sampling and writing `@SpirvType` images from Zig.** Declaration was already
known to work on 0.17-dev.956; the open question was the *operation* (the opaque
image types can't be `OpLoad`ed in plain Zig, so the load + sample/store must go
through inline SPIR-V `asm`, which needs to reference SPIR-V *types* as operands).

## The unlock: the `"t"` (type) asm constraint

The prior spike failed with "failed to assemble SPIR-V inline assembly" because it
tried to bind SPIR-V types as **value** operands. Zig's SPIR-V inline assembler
(see `src/codegen/spirv/CodeGen.zig` `airAsm`) supports three input constraints:

- `"c"` — a compile-time constant (int → literal, enum literal → string).
- `"t"` — a **type**. Resolved via `cg.resolveType(...)`, which returns the
  module's real, **deduped** type id. Passing `"" (value)` for a `type` is a hard
  error ("use the 't' constraint to supply types to SPIR-V inline assembly").
- default — a normal **value**.

Because `"t"` returns the deduped id, `[si_ty] "t" (SampledImage)` yields exactly
the same type id the `@extern` variable points to, so `OpLoad %si_ty %ptr`
type-checks. Inline `OpTypeFloat`/`OpTypeVector` also dedup; `OpTypeImage`/
`OpTypeSampledImage`/`OpTypePointer` declared inline do **not** (`allocId`), which
is why the `"t"` route (not inline type decls) is the correct one.

## Reproduce

```
ZIG=<path to 0.17-dev.956 zig>
$ZIG build-obj src/notes/spikes/spike_sample.zig \
  -target spirv32-vulkan -mcpu vulkan_v1_2 -fno-llvm -fno-lld -O ReleaseFast -ofmt=spirv
$ZIG build-obj src/notes/spikes/spike_store.zig  \
  -target spirv32-vulkan -mcpu vulkan_v1_2 -fno-llvm -fno-lld -O ReleaseFast -ofmt=spirv
```

`spike_sample.zig` → 856-byte .spv: `OpLoad`(SampledImage) + `OpImageSampleImplicitLod` → vec4.
`spike_store.zig`  → 796-byte .spv: `OpLoad`(StorageImage) + `OpImageWrite`.

## @SpirvType API gotchas (validated)

- `Image.format`: enum is `rgba8unorm` (not `rgba8`), `rgba32f`, `r32f`, … or
  `.unknown`.
- `Image.access`: `.write_only`/`.read_only` are **opencl-only**; on
  `spirv32-vulkan` use `.access = .unknown` (Vulkan controls read/write via
  NonReadable/NonWritable decorations, not the image-type access qualifier).
- `Image.usage`: `.{ .sampled = u32 }` for sampled, `.storage` for storage.
- `@extern` IO vars take `.decoration = .{ .location = N }`; descriptor-set
  bindings take `.decoration = .{ .descriptor = .{ .set, .binding } }`.
- Compute entry: `callconv(.{ .spirv_kernel = .{ .x = 8, .y = 8, .z = 1 } })`
  (workgroup size is required). Fragment: `callconv(.{ .spirv_fragment = .{} })`.

## Next (P1)

Wrap the asm in one tested helper pair (`sampleLod` / `imageStore`), re-back
`shader_interface.Sampler2D` with `@SpirvType` (same public API), then teach
spv2wgsl to translate `OpImageSample*`/`OpImageWrite` → `textureSample`/
`textureStore` and emit `@extern` descriptors — retiring the `zspv_rewrite`
sampler machinery and the `zsample2d` placeholder.

- `spike_ssbo_shader.zig` — storage buffers via `zm.storageBuffer`/`ssboLoad`/`ssboStore` (@SpirvType runtime_array). The FIRST end-to-end-working @SpirvType resource path: @extern materializes (runtime bits), asm OpAccessChain access, spv2wgsl → `var<storage>` + `array<T>` indexing.
