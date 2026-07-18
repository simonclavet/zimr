# Zig SPIR-V compiler interface — the contract zimr depends on, and how to recover when it changes

**Read this first whenever a Zig compiler bump breaks shader compilation.** zimr
generates its shaders by compiling Zig to SPIR-V and translating that to WGSL
(`spv2wgsl`). The Zig→SPIR-V half is a **moving, lightly-documented compiler
surface**: builtins, reflection enums, calling conventions, inline-asm grammar.
Every item below has a recorded shape *and* a pointer to where it is defined in
the compiler, so the next person (probably us) can diff reality against this doc
and fix the delta instead of re-deriving the whole thing from scratch.

Recorded against **Zig `0.17.0-dev.956+2dca73595`** (commit `2dca73595`). When
you update the compiler, update the version line here and re-verify every
"Recorded shape" block, ideally by re-compiling the canary spikes (see
[§7](#7-the-canary-spikes)).

---

## 0. The fastest recovery loop

1. **Re-compile the canary spikes** in `src/notes/spikes/` (commands in §7). They
   exercise every surface below; a break names the exact thing that moved.
2. **For reflection/enum/callconv changes** (`@SpirvType` fields, image formats,
   `callconv` options): grep the **local** standard library — these live in
   `lib/std/lang.zig`, which ships in the binary release, so no network:
   ```
   ZL=<zig-install>/lib
   grep -n "Spirv\|SpirvKernelOptions\|SpirvFragmentOptions\|Format\|Dimensionality\|Access" $ZL/std/lang.zig
   ```
3. **For inline-asm grammar changes** (how to reference types/values/constants in
   `asm`): these live in the *compiler source*, which is **not** in the binary
   release. Fetch from GitHub at the compiler's commit (the `+xxxxxxxxx` suffix
   in the version string is the commit). `raw.githubusercontent.com` is an
   allowed bash network domain:
   ```
   REF=2dca73595   # <-- the +suffix of `zig version`
   curl -fsSL https://raw.githubusercontent.com/ziglang/zig/$REF/src/codegen/spirv/Assembler.zig -o /tmp/Assembler.zig
   curl -fsSL https://raw.githubusercontent.com/ziglang/zig/$REF/src/codegen/spirv/CodeGen.zig   -o /tmp/CodeGen.zig
   ```
   In `CodeGen.zig`, search `fn airAsm` for the input-constraint handling; in
   `Assembler.zig`, `processTypeInstruction` / `processGenericInstruction` for
   the asm opcode grammar.
4. **Diff** what you found against the "Recorded shape" blocks below, fix the zm
   helpers (`src/zimrmath.zig`, the `@SpirvType` section) and the spikes, then
   re-run the textured corpus.

---

## 1. Build invocation

SPIR-V objects are built with the **self-hosted** backend (the LLVM backend
segfaults on the spirv target), so `-fno-llvm -fno-lld` are mandatory.

```
zig build-obj shader.zig \
  -target spirv32-vulkan -mcpu vulkan_v1_2 \
  -fno-llvm -fno-lld \
  -O ReleaseFast -ofmt=spirv \
  -femit-bin=out.spv
```

- `spirv32-vulkan` / `-mcpu vulkan_v1_2` — Vulkan environment, SPIR-V 1.x. This
  is what makes `.access = .unknown` (not `.write_only`) correct for storage
  images (§3) and selects the Vulkan descriptor model.
- Without `-fno-llvm -fno-lld`: `zig` tries LLVM for spirv and **segfaults**.

---

## 2. Entry points & calling conventions

A shader entry is an `export fn` with a SPIR-V calling convention. **These are
struct forms now** (they were bare enums on older compilers — a thing that moved):

```zig
export fn fs() callconv(.{ .spirv_fragment = .{} }) void { ... }
export fn vs() callconv(.{ .spirv_vertex = .{} })   void { ... }
export fn cs() callconv(.{ .spirv_kernel = .{ .x = 8, .y = 8, .z = 1 } }) void { ... }
```

- **Compute/kernel REQUIRES an explicit workgroup size** `.{ .x, .y, .z }`
  (`SpirvKernelOptions` in `lib/std/lang.zig`). Omitting it →
  "missing struct field: x".
- The OpEntryPoint interface (the IO variables) is collected automatically from
  the externs the entry transitively references.

---

## 3. `@SpirvType` — declaring opaque resource types

`@SpirvType` builds the SPIR-V opaque/aggregate types Zig has no native syntax
for. **It is only valid on the SPIR-V target** — see §6 for why our helpers wrap
it in functions.

### Recorded shape (from `lib/std/lang.zig`, `Type.Spirv`)

```zig
pub const Spirv = union(enum(u2)) {
    sampler,
    image: Image,
    sampled_image: type,   // wraps an `image` @SpirvType
    runtime_array: type,   // last field of an extern struct; exposes .len + indexing

    pub const Image = struct {
        usage: Usage,           // .{ .unknown = T } | .{ .sampled = T } | .storage
        format: Format,
        dim: Dimensionality,    // .@"1d" | .@"2d" | .@"3d" | .cube
        depth: Depth,           // .unknown | .depth | .not_depth
        access: Access,         // .unknown | .read_only | .write_only | .read_write
        arrayed: bool,
        multisampled: bool,

        pub const Format = enum(u4) {
            unknown, rgba32f, rgba32i, rgba32u, rgba16f, rgba16i, rgba16u,
            rgba8unorm, rgba8snorm, rgba8i, rgba8u, r32f, r32i, r32u,
        };
    };
};
```

### GOTCHAS (each one cost real time)

- **`format`**: the member is `rgba8unorm`, NOT `rgba8`. Sampled images use
  `.format = .unknown` (format is only meaningful for storage images).
- **`access`**: `.read_only` / `.write_only` are **OpenCL-only** and *reject* on
  `spirv32-vulkan` ("access qualifier '.write_only' is only valid under the
  'opencl' os"). On Vulkan use `.access = .unknown`; read/write is expressed via
  `NonReadable` / `NonWritable` **decorations**, not the type.
- **`usage`**: `.{ .sampled = u32 }` for a sampled image, `.storage` for a
  storage image, `.{ .unknown = T }` if neither is known at decl time.
- **`sampled_image`** wraps an `image` type: `@SpirvType(.{ .sampled_image = ImageT })`.

### Examples (validated)

```zig
const Image        = @SpirvType(.{ .image = .{ .usage = .{ .sampled = u32 }, .format = .unknown,
                                               .dim = .@"2d", .depth = .unknown, .arrayed = false,
                                               .multisampled = false, .access = .unknown } });
const SampledImage = @SpirvType(.{ .sampled_image = Image });
const StorageImage = @SpirvType(.{ .image = .{ .usage = .storage, .format = .rgba8unorm,
                                               .dim = .@"2d", .depth = .unknown, .arrayed = false,
                                               .multisampled = false, .access = .unknown } });
const RuntimeArray = @SpirvType(.{ .runtime_array = u32 });
```

---

## 4. `@extern` — binding resources & IO, with decorations

Resources and stage IO are `@extern` pointers in the right address space, with a
`.decoration`:

```zig
// descriptor-set binding (textures, samplers, UBOs, SSBOs):
const tex = @extern(*addrspace(.constant) const SampledImage, .{
    .name = "tex",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 1 } },
});
// stage IO (vertex attrs, varyings, fragment outputs):
const uv  = @extern(*addrspace(.input)  @Vector(2, f32), .{ .name = "uv",    .decoration = .{ .location = 0 } });
const col = @extern(*addrspace(.output) @Vector(4, f32), .{ .name = "color", .decoration = .{ .location = 0 } });
```

The `.descriptor` decoration emits `OpDecorate DescriptorSet/Binding` — it
**replaces** the old hand-written `zm.binding(&v, set, bind)` asm helper.

### Address-space → SPIR-V storage-class map

| Zig addrspace        | SPIR-V storage class | use                            |
|----------------------|----------------------|--------------------------------|
| `.constant`          | UniformConstant      | samplers, images (descriptors) |
| `.input`             | Input                | vertex attrs / varyings in     |
| `.output`            | Output               | varyings out / frag color      |
| `.uniform`           | Uniform              | UBO blocks                     |
| `.storage_buffer`    | StorageBuffer        | SSBOs (runtime arrays)         |
| (function locals)    | Function             | —                              |

### ⚠ KNOWN BLOCKER (956): `@extern` opaque descriptors fold to `OpUndef`

Using an `@extern` whose **pointee is a zero-bit opaque type** (an `@SpirvType`
image or sampler) produces **`OpUndef`** instead of a descriptor `OpVariable` —
the binding silently vanishes, and spv2wgsl sees an undef texture/sampler (it
emits `const undef_N: texture_2d<f32> = texture_2d<f32>()` rather than a
`@group/@binding var`). `color`/`uv` externs survive because `vec4`/`vec2` have
real runtime bits.

Root cause (compiler, `src/codegen/spirv/CodeGen.zig` `constantNavRef`):

```zig
if (!nav_ty.hasRuntimeBits(zcu)) {
    // Pointer to nothing - return undefined.
    return cg.module.constUndef(ty_id);   // <-- before addFunctionDep
}
```

Opaque `@SpirvType` types report `!hasRuntimeBits`, so a reference bails to undef
**before** `addFunctionDep` registers the global — so the `OpVariable` is never
emitted. The behavior test (`test/behavior/spirv.zig`) does not catch this: it
only `_ = sampled_image;`s the externs (declares), never *uses* one in a shader.

This blocks the clean `@SpirvType` sampler path at P3. Workaround candidates (for
next time / when the compiler is bumped):
- **Compiler fix** — emit the `OpVariable` (+ register the dep) for zero-bit
  opaque `@extern` descriptors. Re-test with `spike_texture_shader.zig`; if a
  newer compiler emits a real `OpVariable` in `.constant` storage, the whole
  path lights up unchanged.
- **asm-declared `OpVariable`** — ❌ **DEAD on 956 (compiler segfault).** Declaring
  a non-Function (global) `OpVariable` inside body inline-asm crashes codegen
  (exit 139) regardless of element type — confirmed with both a zero-bit opaque
  image *and* a plain `u32` (`/tmp/asmvar2.zig`, `/tmp/asmu32.zig`). The assembler
  does not route a body-asm global `OpVariable` to the globals section; it faults.
  So the descriptor variable cannot be hand-declared in asm on this compiler — the
  binding must come from `@extern`, which hits the OpUndef bail above. Both sampler
  routes therefore need a **compiler fix**; revisit on the next nightly.
- **Stay on `zsample2d`/`zspv_rewrite`** (the u32-placeholder path, which
  materializes because u32 has runtime bits) until one of the above lands.

---

## 5. Inline SPIR-V assembly — the part that blocked us for a session

Opaque types (images/samplers) can't be `OpLoad`ed by plain Zig
("cannot load uninstantiable type"), so the load + the sample/store **op** must
be written as inline SPIR-V `asm`. The asm references SPIR-V **types** as
operands — and that is where the prior spike died with *"failed to assemble
SPIR-V inline assembly"*, because it bound types as **value** operands.

### The three input constraints (from `CodeGen.zig` `airAsm`)

| constraint | input is…            | becomes (in the assembler)        |
|------------|----------------------|-----------------------------------|
| `"c"`      | a comptime constant  | int → literal word; enum literal → string |
| **`"t"`**  | **a type** (or a value, whose type is taken) | `.ty` = `cg.resolveType(...)`, the module's **deduped** type id |
| (default)  | a runtime value      | `.value` = the value's result id  |

- Passing a `type` with the default constraint is a hard error: *"use the 't'
  constraint to supply types to SPIR-V inline assembly."*
- **Why `"t"` is the whole answer:** `cg.resolveType` returns the *deduped* id,
  so `[si_ty] "t" (SampledImage)` yields exactly the id the `@extern` variable
  points to → `OpLoad %si_ty %ptr` type-checks. (Declaring the type *inline* in
  the asm instead — `%si_ty = OpTypeSampledImage ...` — does NOT dedup for
  image/sampled-image/pointer types; the assembler `allocId`s a fresh id. So
  `"t"` is the *only* correct route for opaque types.)

### Asm syntax recap (from `Assembler.zig`)

- `%name` — a local result id; `%name = Op...` assigns, bare `%name` references.
- `$name` — substitutes a `"c"` constant operand inline (e.g. `OpDecorate %t Location $n`).
- Outputs: `: [res] "" (-> T)` binds Zig return type `T` to `%res`.
- Inline type decls dedup for scalars/vectors (`OpTypeFloat`/`OpTypeVector` via
  `module.floatType`/`vectorType`) but **not** for image/sampled-image/pointer/
  runtime-array (`module.allocId` → fresh id). Use `"t"` for those.

### The proven helpers (now in `src/zimrmath.zig`)

```zig
pub fn sampleLod(tex: Texture2DPtr(), uv: Vec2) Vec {
    return asm volatile (
        \\%si  = OpLoad %si_ty %tex
        \\%res = OpImageSampleImplicitLod %v4f %si %uv
        : [res] "" (-> Vec),
        : [si_ty] "t" (Texture2D()),   // type via "t"
          [v4f]   "t" (Vec),           // result type via "t"
          [tex]   ""  (tex),           // value
          [uv]    ""  (uv),            // value
    );
}
```

`imageStore` is identical in shape with `OpImageWrite` (no result). Both are
proven in `src/notes/spikes/`.

> `OpImageSampleImplicitLod` needs screen-space derivatives → **fragment stage
> only**. For vertex/compute use `OpImageSampleExplicitLod` with an explicit Lod
> operand (not yet wrapped).

---

## 6. Why the helpers are `fn`s, not file-scope `const`s (the host-build trap)

`@SpirvType` is invalid off the SPIR-V target, but `src/zimrmath.zig` (where the
shader helpers live, so a shader gets everything from one `@import("zm")`) ALSO
compiles to **wasm32/host**. A file-scope `const T = @SpirvType(...)` is analyzed
**eagerly** and breaks every host build. Wrapping each type in a `pub fn ... type`
(and each op in a `pub fn` with an asm body) keeps it behind Zig's **lazy
analysis**: a `pub fn` is analyzed only when referenced, and only shaders (built
for SPIR-V) reference these.

**RULE:** never reference `Texture2D` / `texture2D` / `sampleLod` /
`StorageImage2D` / `imageStore` (or any future `@SpirvType` helper) from host
code or a host `test`. Doing so forces eager SPIR-V analysis on the host target
and breaks the wasm/host build. Verify after any change with:
```
zig build-obj src/zimrmath.zig -target wasm32-wasi -O ReleaseSmall   # must succeed
```

---

## 7. The canary spikes

`src/notes/spikes/` holds minimal, self-contained proofs — the **first thing to
recompile** after a compiler bump (a break points straight at the moved surface):

| file                       | proves                                                   |
|----------------------------|----------------------------------------------------------|
| `spike_sample.zig`         | `@SpirvType` sampled image + `OpImageSampleImplicitLod` (the `"t"` constraint) |
| `spike_store.zig`          | `@SpirvType` storage image + `OpImageWrite`              |
| `spike_texture_shader.zig` | the **zm helpers** (`texture2D`/`sampleLod`) from a real shader importing `zm` |

```
ZIG=<zig-install>/zig
F="-target spirv32-vulkan -mcpu vulkan_v1_2 -fno-llvm -fno-lld -O ReleaseFast -ofmt=spirv"
$ZIG build-obj src/notes/spikes/spike_sample.zig $F -femit-bin=/tmp/a.spv   # ~856 B
$ZIG build-obj src/notes/spikes/spike_store.zig  $F -femit-bin=/tmp/b.spv   # ~796 B
# (spike_texture_shader.zig imports ../../zimrmath.zig; copy both to one dir to
#  satisfy Zig's module-path rule, or build it through the normal shader graph.)
```

Verify the ops landed by parsing the `.spv` (little-endian u32 words; opcode is
`word & 0xffff`): `OpImageSampleImplicitLod` = 87, `OpImageWrite` = 99,
`OpTypeSampledImage` = 27, `OpTypeImage` = 25, `OpLoad` = 61.

---

## 8. What `std.spirv` does and does NOT give us

`lib/std/spirv.zig` (recorded: 84 lines) provides only the built-in IO externs
(`position_in/out`, `point_size_in/out`) and barriers (`controlBarrier`,
`memoryBarrier`, `workgroupBarrier`). It has **no spec-constant support** and
**no image-sample/store builtins** — which is exactly why §5 exists (we DIY the
ops via `"t"`-constrained asm).

**`override` / spec constants are still unsolved** (blocks bloom authoring): no
clean Zig path to *declare* a spec constant. Current recommendation: migrate
bloom with a per-pass FS-UBO instead, and leave `pipeline_constants` until/unless
spec-constant authoring is built.

---

## 9. Known move history (so we recognize the pattern)

These have each already shifted at least once; expect more:

- `std.gpu` → **`std.spirv`** (module rename).
- Bare-enum exec-mode callconv → **struct form** (`callconv(.{ .spirv_fragment = .{} })`);
  compute gained a required workgroup size.
- The image-op asm: types must go through the **`"t"` constraint**
  (`CodeGen.zig airAsm`). This was the multi-session blocker; it is the single
  most likely thing to silently change shape.
- Reflection types live in `lib/std/lang.zig` (were under `std.builtin` in older
  trees) — `Type.Spirv.*`, `SpirvKernelOptions`, etc.

---

## 10. The two shader paths (migration status)

- **OLD (`zspv_rewrite`)** — shader declares `extern const s: u32`, decorates
  with `zm.binding`, samples with `zm.zsample2d` (placeholder). `tools/zspv_rewrite.zig`
  post-processes the `.spv` into real sampler machinery, under a **limited
  spirv-opt pass list** (so the placeholder survives to be rewritten). Fragile,
  version-sensitive, blocks full `-O`.
- **NEW (`@SpirvType`)** — shader uses `zm.texture2D` + `zm.sampleLod`; the real
  `OpTypeSampledImage` + `OpImageSampleImplicitLod` are emitted directly. No
  rewrite, full `spirv-opt -O` runs again.

**Status:** P0 (sample/store ops) ✅. P1 (zm helpers) ✅. **Storage buffers
(runtime arrays) ✅ END-TO-END** — the OpUndef blocker is opaque-specific, so a
runtime-array struct's @extern materializes as a real `var<storage>` binding;
spv2wgsl now handles `OpTypeRuntimeArray`, and `zm.ssboLoad`/`ssboStore` index via
asm `OpAccessChain` (plain-Zig field access mis-lowers on 956). The OpName rule was
generalized to "prefer `kbuf_`, else last-wins" so two buffers through one inline
helper keep distinct names. **Samplers/storage-images ❌ BLOCKED** by the opaque
`@extern` → OpUndef issue above (needs a compiler fix or the asm-OpVariable
workaround). Next: migrate a real storage-buffer example onto the helpers +
device-verify; then the sampler path once unblocked, then retire
`tools/zspv_rewrite.zig` + `zm.zsample2d` (see `claude.md` PHASES P3–P5).
