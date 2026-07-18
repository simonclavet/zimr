# Shader style guide

Style rules for `.fs.zig` / `.vs.zig` files that go through the
Zig-shader pipeline.  Companion to `src/notes/tutorials/zig-shader-tutorial.md`
(the how-to) — this file is a short reference of dos and don'ts.

Pipeline:
```
*.fs.zig / *.vs.zig
    → zig build-obj -target spirv32-vulkan -mcpu vulkan_v1_2
            -fno-llvm -fno-lld -O ReleaseFast -ofmt=spirv
    → spirv-opt -O --skip-validation
    → spirv-val
    → spirv-cross --version 300 --es
    → @embedFile-able GLSL ES 3.0
```

## File-level

- **File name**: `<example>.fs.zig` for fragment, `<example>.vs.zig`
  for vertex.  Sibling to the host file.  Engine shaders live under
  `src/shaders/` with `<role>_fs.zig` / `<role>_vs.zig`.
- **Import shadermath as `zm`**:
  ```zig
  const zm = @import("shadermath");
  ```
  Matches the CPU-side spelling — the same `zm.dot`, `zm.length`,
  `zm.atan2`, `zm.tau` work in both worlds.

## Entry point

- **`export fn main` with `callconv(.spirv_fragment)` or
  `.spirv_vertex`**.  Triggers `OpEntryPoint` emission.  Without
  the callconv, spirv-cross errors with "no entry point in the
  SPIR-V module."

## Interface variables

- **`extern const x: T addrspace(.input)`** for stage inputs
  (varyings from VS / vertex attributes).
- **`extern var x: T addrspace(.output)`** for stage outputs.
  Must be `var` (the entry point writes to it), not `const`.
- **`extern const u: Uniforms addrspace(.uniform)`** for UBO blocks.
  Must be paired with `zm.binding(&u, set, bind)` inside `main`
  to attach the descriptor-set + binding-point decoration.

### Naming for varyings during the engine-default-VS era

Engine VS uses camelCase (`fragTexCoord`, `fragColor`).  Until the
engine VS migrates to the pipeline (S1.5), `.fs.zig` files paired
with the default VS MUST declare their inputs with the matching
camelCase names — the GL linker rejects mismatched varying names.

```zig
extern const fragTexCoord: zm.Vec2 addrspace(.input);
extern const fragColor: zm.Vec addrspace(.input);
```

## Uniforms — two paths

**Path A: UBO block (preferred for grouped uniforms).**
Group uniforms into one `extern struct`, declare a single
`extern const u: Uniforms addrspace(.uniform);`, decorate with
`zm.binding`.  Host side uses `UniformBuffer(Uniforms)`.

**Path B: individual loose uniform via `addrspace(.constant)`.**
Use when only one or two uniforms need to live separately (the
engine's `view`/`projection`/`mvp` is the canonical case — set
by the engine via `rlSetUniform` against the raylib-parity
`SHADER_LOC_*` table).  Maps to SPIR-V storage class
`UniformConstant` → spirv-cross emits a plain GLSL loose uniform:

```zig
extern const u_zoom: f32 addrspace(.constant);
// → `uniform float u_zoom;` in GLSL ES.
```

Don't use `addrspace(.uniform)` for individual uniforms.  Zig's
SPIR-V backend emits those in storage class `Uniform`
(UBO-interior), but without a buffer block around them
spirv-cross can't reconcile with GLSL's loose-uniform shape —
the emitted GLSL references them in the body without declaring
them at top, and WebGL rejects the program.  `addrspace(.uniform)`
is ONLY for grouped UBO blocks (Path A).

### std140 layout — the pitfalls

The host-side mirror struct MUST have the same byte layout as the
shader's `Uniforms`.  `UniformBuffer(T)` checks `@sizeOf(T) % 16 == 0`
at comptime; subtler offset mismatches are silent at compile time
but visible in `spirv-cross --reflect`.

- **Trailing pad fields are individual `f32`s, not `[N]f32`**.
  std140 stride for an array-of-float rounds each element to vec4
  (16 bytes), so `[3]f32` becomes 48 bytes per std140 vs 12 bytes
  in Zig.  Use:
  ```zig
  _pad1: f32 = 0,
  _pad2: f32 = 0,
  _pad3: f32 = 0,
  ```
- **`vec2` needs 8-byte alignment**.  After a single `f32` you'll
  often want a 4-byte pad to push the next `vec2` to an 8-aligned
  offset.
- **`vec3` needs 16-byte alignment AND consumes 16 bytes** (the 4th
  lane is reserved).  Prefer `Vec` (4-comp) for stored uniforms;
  use `Vec3` for compute temporaries inside the shader.
- **Struct total size rounds up to 16 bytes** (vec4 boundary).

## Zig-language gotchas in SPIR-V codegen

- **No `bool` storage**.  Zig codegens `bool` as `u1` → spirv-cross
  emits `uint8_t` → WebGL2 rejects (needs int8 extension).  Use
  `u32` flags: `var escaped: u32 = 0;` then `escaped = 1`.
- **Wrapping arithmetic for integer increments**: `+%=`, `-%=`,
  `*%=`.  Without them Zig emits overflow checks as `OpIAddCarry`
  struct packs.
- **No `pub inline fn` (or `inline fn`)** in shader DSL helpers
  or example code.  Zig's SPIR-V backend emits structured-control-flow
  markers around inline functions that bake in as `if (X == X)`
  constant branches.  Plain `pub fn` (or `fn`); let `spirv-opt -O`
  inline at SPIR-V level.
- **`-O ReleaseFast`** is mandatory for compile.  Debug builds emit
  runtime safety checks that don't translate to GLSL.
- **`-fno-llvm -fno-lld`** mandatory.  Default LLVM segfaults on
  spirv targets in Zig 0.16.

## Texture sampling — sample at the top, never in a branch

WGSL forbids calling an implicit-LOD sampler (`textureSample`, which
needs screen-space derivatives) from non-uniform control flow.  Tint
(Chrome's validator) rejects it with *"'textureSample' must only be
called from uniform control flow."*  **Important: neither `naga` nor
`nagac` enforces this** — both happily validate a sample inside an
`if` — so the only runtime authority is Tint, and the only build-time
authority is the lint below.

- **Take every texture sample unconditionally at the top of
  `shaderMain`**, before any `if`/`while`/`for`, and thread the sampled
  value down into the lighting/shadow/branch code.  The function's entry
  region (before the first branch) is the one place a sample is provably
  uniform.
- **Don't sample inside a branch or loop** — `if (i == 0) {
  io.shadow_map(uv); }`, `while (...) { io.normal(uv); }`, etc.
- **Don't sample in a helper fn.**  A helper can be called conditionally
  (`if (i == 0) computeShadow(...)`), which puts its sample in
  non-uniform flow.  Instead, sample at `shaderMain`'s top and pass the
  value in as a parameter — e.g. `computeShadow` takes a pre-sampled
  `closest_depth: f32` and a pure `proj_coords: Vec3`, and does no
  sampling itself.
- Sampling a map that's unused (or when a feature like shadows is off)
  is harmless: the value is simply discarded downstream.

This is enforced mechanically by `tools/lint_zimr.zig` (tags
`sampler-in-branch` / `sampler-in-helper`).  Two detection paths:

- **IoT shaders**: samplers are the only *callable* members of an `Io`
  struct (uniforms and inputs are plain fields, read without `()`), so
  any `io.<method>(...)` call is a texture sample, flagged unless it's a
  non-nested statement of `shaderMain`.
- **Direct `@SpirvType` shaders** (billboard/skybox/points/decal …): the
  exported `entry` fn has no `Io` param, so it's matched by CALLEE NAME
  instead — a `zsample2d(...)` / `zm.zsample2d(...)` call is a sample and
  is held to the same top-of-`entry` rule.  (`sampleLod`/explicit-LOD
  variants take no derivatives and are exempt.)  This path was added
  after a decal shader sampled inside an `if (inside)` branch and slipped
  past the IoT-only check — Tint rejected it at runtime, nothing at build.

## Math builtins

Zig builtin → SPIR-V status, in 0.16:

| Builtin    | Works? | Notes                             |
|------------|--------|-----------------------------------|
| `@sqrt`    | ✓      |                                   |
| `@sin`     | ✓      |                                   |
| `@cos`     | ✓      |                                   |
| `@exp`     | ✓      |                                   |
| `@log`     | ✓      |                                   |
| `@log2`    | ✓      |                                   |
| `@floor`   | ✓      |                                   |
| `@ceil`    | ✓      |                                   |
| `@abs`     | ✓      |                                   |
| `@max` / `@min` | ✓ | both arity-2                      |
| `@atan`    | ✗      | use `zm.atan2`                    |
| `@atan2`   | ✗      | use `zm.atan2`                    |

For anything else from `std.math` that you'd want in a shader,
re-export it in `shadermath.zig` (matching the pattern of
`pub const clamp = std.math.clamp;`).  Don't `@import("std")`
inside `.fs.zig` / `.vs.zig` — keep the surface inside `zm.*`.

## Decorators (inline SPIR-V asm)

Zig 0.16's `std.gpu` ships built-ins but not decoration helpers.
`shadermath.zig` declares the ones we need via inline asm:

- `zm.location(&var, n)` — `Location n` on inputs / outputs.
- `zm.binding(&var, set, bind)` — `DescriptorSet set` + `Binding bind`
  on UBOs.

### Inline-asm operand naming

```zig
asm volatile (
    \\OpDecorate %target Location $n
    :
    : [target] "" (ptr),
      [n] "c" (n),
);
```

**Use `target` (or similar generic name), not the variable's real
name**, for the operand label.  Operand names leak as SPIR-V debug
names and would overwrite the real SSA name in the output GLSL.

## Manual-pipeline scratch directory

When invoking the pipeline stages manually for debugging
(`zig build-obj ...`, `spirv-opt`, `spirv-cross`), write all
intermediate artifacts to `shadertemp/` rather than the repo
root.  The folder is gitignored.  Production compiles go through
the Zig build cache (`.zig-cache/`); `shadertemp/` is only for
ad-hoc inspection.

```
zig build-obj ... -femit-bin=shadertemp/foo.spv ...
tools/zig-out/bin/spirv-opt.exe -O --skip-validation \
    shadertemp/foo.spv -o shadertemp/foo.opt.spv
tools/zig-out/bin/spirv-cross.exe --version 300 --es \
    shadertemp/foo.opt.spv --output shadertemp/foo.glsl
```

## spirv-opt invocation

Use the canned preset, not granular `--eliminate-dead-*` passes.
The preset runs dead-branch-elim → merge-return → inline → dead-strip
in the correct order.  Without inlining, every DSL helper survives
as a separate function in the GLSL output.

```
spirv-opt -O --skip-validation
```

`--skip-validation` is required because Zig 0.16's std-imports emit
a dead `Target_Cpu` struct that the validator rejects with
"Instruction may not have a logical pointer operand"; spirv-opt's
`-O` strips it on its next pass.

## Common patterns

### Fragment shader with UBO

```zig
const zm = @import("shadermath");

extern const fragTexCoord: zm.Vec2 addrspace(.input);
extern const fragColor: zm.Vec addrspace(.input);
extern var out_color: zm.Vec addrspace(.output);

const Uniforms = extern struct {
    color: zm.Vec,
    // any padding fields...
};
extern const u: Uniforms addrspace(.uniform);

export fn main() callconv(.spirv_fragment) void {
    zm.location(&out_color, 0);
    zm.binding(&u, 0, 0);
    _ = fragColor;
    out_color = u.color * zm.vec4(fragTexCoord[0], fragTexCoord[1], 1, 1);
}
```

### Helper function

```zig
fn hsv2rgb(c: zm.Vec3) zm.Vec3 {
    // ... pure pub fn (NOT inline) ...
}
```

## Anti-patterns (what NOT to do)

- ❌ `var escaped: bool = false;` — use `u32` flag.
- ❌ `i += 1` in a `while` index — use `i +%= 1`.
- ❌ `pub inline fn helper(...)` — drop `inline`.
- ❌ `extern const u_zoom: f32 addrspace(.uniform);` — bundle into
  UBO, or use `addrspace(.constant)` for a loose uniform.
- ❌ `_pad: [3]f32 = .{0,0,0}` — use three individual `_padN: f32`.
- ❌ `@atan(x)` / `@atan2(y, x)` — use `zm.atan2(y, x)`.
- ❌ `const sm = @import("shadermath");` — use `zm` for parity with CPU.
- ❌ Importing `std` in a shader file — re-export via `shadermath`.
