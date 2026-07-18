# Zig shader pipeline — precise plan

Last updated: this session.  Replaces earlier exploratory plan; the
previous version's discovery notes are preserved in §4 (appendix).

## 0. Status — what's locked in

### 0.1 Pipeline architecture

```
*.fs.zig / *.vs.zig (Zig source)
    │ zig build-obj -target spirv32-vulkan -ofmt=spirv -mcpu vulkan_v1_2
    │     -fno-llvm -fno-lld -O ReleaseFast
    ▼
*.spv (raw SPIR-V — has OpEntryPoint + OpExecutionMode)
    │ spirv-opt -O   (inline + merge-return + dead-strip)
    ▼
*.opt.spv (clean SPIR-V)
    │ spirv-cross --version 300 --es
    ▼
*.glsl (GLSL ES 3.0 — WebGL2-ready)
    │ @embedFile in host Zig code via build.zig addAnonymousImport
    ▼
shader bytes baked into wasm
```

Tools: Zig (already in `tools/`), SPIRV-Tools (provides `spirv-opt`),
SPIRV-Cross (provides `spirv-cross`).  Last two vendored from source
via `addCSourceFiles`.

### 0.2 Type vocabulary

| name  | type                | math.zig (CPU)        | shadermath.zig (GPU) |
|-------|---------------------|-----------------------|----------------------|
| `Vec` | `@Vector(4, f32)`   | ✅ SIMD workhorse     | ✅ 4-comp values     |
| `Vec2`| `@Vector(2, f32)`   | ✅                    | ✅                   |
| `Vec3`| `@Vector(3, f32)`   | ❌ use `Vec`          | ✅ 3-comp values     |
| `Mat` | `[4]Vec`            | ✅                    | ✅                   |

No `Vec4` — `Vec` IS `@Vector(4, f32)`; one canonical name.

### 0.3 API parity — same names in both files

`math.zig` and `shadermath.zig` are independent files with mirrored
public APIs for overlapping concepts.  Adding a helper in one means
adding it in the other.

Shared helper names:
- Types: `Vec`, `Vec2`, `Mat`, plus `Vec3` in shadermath only
- Scalar: `clamp01`, `mix` (alias of zmath `lerp`), `pow`, `log2`,
  `fract`, `smoothstep`, `step`
- Vector: generic `dot`, `length`, `distance`, `normalize`
  (math.zig keeps `dot3`/`length3`/`normalize3` for SIMD-hot paths;
  shadermath skips them — no Vec vs Vec3 ambiguity on GPU)
- Swizzle: `x(v)`, `y(v)`, `z(v)`, `w(v)`, `sw(v, "xyz")` — exact
  same comptime-shuffle implementation on both sides

GPU-only (shadermath.zig only):
- `location(comptime target, comptime n)` — inline SPIR-V asm
- `binding(comptime target, comptime set, comptime bind)` — inline asm

### 0.4 Uniform style — UBO blocks (Uniform Buffer Objects)

**Decision reversed (this session).**  Original plan was individual
`extern const` uniforms with `addrspace(.uniform)`.  Investigation
during the mid-S1.3 PoC revival showed that path is a dead end on
Zig 0.16: `addrspace(.uniform)` emits SPIR-V storage class `Uniform`
(which is the UBO interior storage class), but the variables aren't
grouped in a buffer block — so spirv-cross emits dangling references
in the GLSL body without top-level declarations, and WebGL rejects
the shader.  See §4 appendix entry "Uniform without UBO is a
dead-reference fail" for the disassembly trace.

Two ways out:
- (a) Inline-asm hack to force storage class `UniformConstant` so
  individual uniforms work like raylib's `glUniform*`.  **Rejected**
  — throwaway work that gets deleted at the next migration, and
  WebGPU has no `UniformConstant` equivalent so it doesn't survive
  the eventual backend swap anyway.
- (b) **Group uniforms into UBO blocks.**  Chosen.  Matches
  SPIR-V's `Uniform` storage class, matches WebGPU's
  `@group(N) @binding(M) var<uniform> u: Uniforms;` shape, matches
  Vulkan's native ABI.  Host side: one `glBufferData` per UBO per
  frame instead of N `glUniform*` calls.

```zig
const Uniforms = extern struct {
    u_center: sm.Vec2,
    u_zoom: f32,
    _pad0: f32 = 0,                // std140 16-byte alignment
    u_resolution: sm.Vec2,
    u_max_iter: f32,
    _pad1: f32 = 0,
};
extern const u: Uniforms addrspace(.uniform);

export fn main() callconv(.spirv_fragment) void {
    sm.binding(&u, 0, 0);          // descriptor set 0, binding 0
    // ... use u.u_center, u.u_zoom, ...
}
```

Engine impact: `setShaderValue` for raylib parity stays for the
inline-GLSL shaders; new pipeline shaders go through a typed-UBO
loader that maps a Zig `extern struct` to a single `glBufferData`
call.  Concrete shape lands in S1.2.

### 0.5 Uniform naming — snake_case

Forward-looking.  Engine-wide rename in S0 (pre-pass).

### 0.6 File layout

- **Examples**: sibling files.  `examples/mandelbrot.zig` +
  `examples/mandelbrot.fs.zig` next to each other.
- **Engine**: dedicated dir.  `src/shaders/pbr_fs.zig`,
  `src/shaders/pbr_vs.zig`, etc.

### 0.7 Default vertex shader

Keep empty-string convention during S1.3–S1.4 (`loadShaderFromMemory("", fs_source)`
substitutes the engine default).  Default VS migrates as part of
S1.5's engine-shader batch.

### 0.8 RESOLVED — sampler/texture support (S1.4.5)

**Update**: S1.4.5b derisked in a later session — the inline-asm path
has structural issues; the refined design uses GLSL post-processing
instead.  See `src/notes/s1.4.5b-sampler-derisk.md` for the full
investigation and revised design.


Investigation outcome:

**(a) `addrspace(.constant)` works for non-opaque types.**  A
`u32`/`f32`/`Vec2` extern with `addrspace(.constant)` emits SPIR-V
storage class `UniformConstant`, and spirv-cross renders it as
a plain GLSL ES loose uniform (`uniform uint tex;` style).
Compiles, validates, reflects clean (loose uniforms don't appear
in `--reflect` JSON — only UBOs/SSBOs do, but the GLSL output is
correct).  This is the missing-piece for individual non-UBO
uniforms — the path the engine's `view`/`projection`/`mvp` can
follow once migrated.

**(b) Sampler-typed variables: pending inline-asm sub-arc.**
SPIR-V samplers need `OpTypeSampledImage` (or `OpTypeImage` +
separate `OpTypeSampler`).  Zig has no source-level type that
maps to either — `opaque {}` trips "cannot generate opaque type"
when passed through generic helpers; `extern struct {}` compiles
but emits an empty-struct SPIR-V type, not a sampled-image type.

The path forward is all-inline-asm: build a `Sampler2D`
shadermath helper that wraps `OpTypeImage` + `OpTypeSampledImage`
+ `OpImageSampleImplicitLod` in asm strings, decorated with
`DescriptorSet` + `Binding`.  Scoped as S1.4.5b — 1-2 sessions,
to land before S1.5 batch 2 (texture-using engine shaders) so
they can migrate via the DSL rather than staying inline GLSL.

Zig 0.16's `addrspace` enum still has no `uniform_constant`
variant.  S1.4.5 investigates:
1. Does `addrspace(.constant)` with an opaque type produce a
   usable `UniformConstant` variable?
2. If not, can samplers be declared entirely via inline asm?
3. Same for `OpImageSampleImplicitLod` (the sample call).

**9 of 12 zimr shaders are sampler-free** — migrate those first
(via UBOs, no `UniformConstant` needed); the 3 texture-using
engine shaders + chromatic-aberration example wait until S1.4.5
resolves the sampler-specific bit.

### 0.9 Forward compatibility — `@Vector` proposal #32032

Zig has an accepted proposal extending `@Vector` with shader-friendly
ergonomics: `.xyz`/`.rgb` field access, `v.xxy`-style swizzles, `++`
concatenation, scalar×vector multiplication, and an explicit
`layout: enum { auto, array }` argument distinguishing SIMD-aligned
from packed storage.  Not landed yet, no firm date.  Reference:
ziglang/zig#32032 (proposal text and prior-art comparison).

**Our design discipline so this upgrade stays a one-day refactor**:

1. **Keep `shadermath.zig` helpers as thin call-through shims.**
   Every helper is a one-liner over a native `@Vector` op.  No
   helper composes other helpers; no deep abstractions.  When the
   proposal lands we delete the file body and update aliases.
2. **Use vector literals (`Vec3{ x, y, z }`), not constructor
   functions (`sm.vec3(x, y, z)`), in new shader code.**  The
   literal form already works and matches the post-proposal world.
   Constructors stay around as a transitional convenience but new
   `.fs.zig` files should prefer literals.
3. **`Vec2` / `Vec3` / `Vec` aliases under shadermath own their
   layout argument when it lands.**  Stored vectors (UBO fields)
   become `@Vector(N, f32, .array)`; hot-path temporaries stay
   `@Vector(N, f32, .auto)` (the current default).  Until the
   proposal lands, all aliases are `@Vector(N, f32)` and the
   layout choice is implicit.  When upgrading, only the alias
   definitions in `shadermath.zig` and the few host-side struct
   field types need editing — call sites referencing `Vec3` etc.
   stay unchanged.
4. **Don't reach for swizzle / field-access syntax in CPU-side
   code yet** (`math.zig`).  Today's `@Vector(N, f32)` doesn't
   support it; using helpers in CPU code keeps the two sides
   ergonomically equivalent.  When the proposal lands and stabilizes,
   migrate both sides together.

**Concrete migration estimate** (assuming proposal ships unchanged):
- `shadermath.zig` body shrinks ~40%: the swizzle helpers, field
  accessors, and per-arity `splatN` helpers all become native
  syntax and get deleted.
- Existing `.fs.zig` shader sources need a near-mechanical pass:
  `sm.x(v)` → `v.x`, `v * sm.splat3(s)` → `v * s`,
  `sm.sw(v, "xyz")` → `v.xyz`.  ~2 hours per shader, perfectly
  scriptable.
- `math.zig` (CPU side) stays unchanged structurally; can migrate
  to dot syntax opportunistically.
- UBO struct fields gain `.array` layout — one line edit per
  aliased vector type.

No part of this migration breaks the public API of zimr (`z.*`).
The shader-author surface gets ergonomic upgrades; the engine
surface is untouched.

## 1. Turn-by-turn schedule

Tests + lint must be green at end of every turn.  Each turn is
one self-contained session.

### S0 — Engine-wide snake_case rename (pre-pass)

Pure refactor, no new mechanism.  Find/replace pass across:

**GLSL shader strings** (rename uniforms inside the `\\uniform vec4 ...`
literals):
- `src/rlgl.zig`: DEFAULT_VS, DEFAULT_VS_SKINNED, DEFAULT_FS
- `src/render.zig`: pbr_vs, pbr_fs, shadow_vs, shadow_fs, skybox_vs,
  skybox_fs
- `src/drawing.zig`: SKYBOX_VS, SKYBOX_FS (audit for dupes)
- `examples/{mandelbrot,shader,shader_uniforms,instancing}.zig`

**Engine call sites** — every `getShaderLocation` + `setShaderValue`
that references a renamed uniform.  In:
- `src/rlgl.zig`, `src/render.zig`, `src/drawing.zig`,
  `src/scene.zig`, `src/entities.zig`, plus anywhere a renamed
  string literal appears.

**Renames (engine-wide)**:
- `colDiffuse` → `col_diffuse`
- `matModel` → `mat_model`
- `matView` → `mat_view`
- `matProjection` → `mat_projection`
- `matNormal` → `mat_normal`
- `instanceTransform` → `instance_transform`
- (others surfaced by grep — `uColor`?  Audit.)

**Renames (per-example)**:
- mandelbrot: `uCenter` → `u_center`, etc.
- shader_uniforms: `uTime` → `u_time`, etc.
- shader: `uOffset` → `u_offset`, etc.
- instancing: any custom names

**Stay as-is (already lowercase / single word)**:
- `mvp`, `texture0`/`texture1`/`texture2`
- Attributes/varyings (`vertex_position`, `fragTexCoord`, etc.) —
  NOT uniforms; touch in S1.5 alongside engine VS migration.

**Test criteria**: tests 1864/1864, lint 0 issues, no visual
regression on mandelbrot/shader_uniforms standalones.

**Scope**: ~30-50 string-literal touches.  Single session.

### S1.1 — Vendor SPIRV-Tools + SPIRV-Cross

Stage source under `tools/SPIRV-Tools/` + `tools/SPIRV-Cross/`.
Add `build_shader_tools.zig` (top-level alongside `build.zig`)
that compiles both via `addExecutable` + `addCSourceFiles`.
Both target-native (Linux); cross-compile to Windows is a later
follow-up.

**Test criteria**:
- `tools/spirv-opt --version` exits 0
- `tools/spirv-cross --help` exits 0
- `zig build test` still 1864/1864
- Lint green

**Risk**: SPIRV-Tools has a Python codegen step (enum tables from
grammar files).  Investigate first thing in S1.1; if it's a
quagmire, pre-generate the tables once and check them into the
vendored tree.

**Scope**: ~200 LOC build.zig + vendored source.  Single session.

### S1.2 — Build pipeline helper + shadermath.zig + math.zig parity + UBO machinery

Four deliverables in one turn (was three; UBO machinery added after
the §0.4 reversal).

**(a) `ShaderBuild` helper in build.zig**:
```zig
const ShaderBuild = struct {
    b: *std.Build,
    spv_target: std.Build.ResolvedTarget,
    spirv_opt: *std.Build.Step.Compile,
    spirv_cross: *std.Build.Step.Compile,
    fn compileShader(...) std.Build.LazyPath { ... }
    fn addShader(...) void { ... }
};
```

**(b) `src/shadermath.zig`** — the DSL.  Types per §0.2; helpers
per §0.3; decorators per §0.3 GPU-only section.  Plus a UBO
convention block (see (d) below) documenting:
- the `extern struct` + `extern const u: Uniforms addrspace(.uniform)`
  pattern
- the required `sm.binding(&u, set, bind)` decoration call in `main()`
- std140 alignment rules (vec3 padded to 16 bytes, mat3 padded to
  vec4-aligned rows, etc.) and the helper macros / pad-fields pattern

**(c) `src/math.zig` additions** — pure additions, no rename of
existing zmath functions.  Add the §0.3 shared helpers:
`Vec3`, `clamp01`, `mix`, `fract`, `smoothstep`, `step`, generic
`dot`/`length`/`normalize`/`distance`, swizzles (`x`/`y`/`z`/`w`/`sw`).

**(d) UBO host-side machinery in `src/shaders.zig`** (or `src/rlgl.zig`,
TBD by integration point):
- `pub fn createUniformBuffer(gl, comptime T: type) UniformBuffer(T)` —
  allocates a GL buffer object sized to `@sizeOf(T)`, binds it to a
  binding point.
- `pub fn pushUniforms(gl, ub, value: T) void` — single
  `glBufferSubData` (or `glBufferData` with `STREAM_DRAW`) per frame;
  this replaces the N `setShaderValue` calls of the raylib path for
  pipeline shaders.
- `pub fn bindUniforms(gl, shader, ub, binding: u32) void` — wires
  the UBO to the shader program's UBO binding slot.
- Std140 layout validation: `comptime` walk of the struct verifies
  field offsets match std140 expectations; mismatches are a compile
  error pointing at the offending field.

Raylib-parity `setShaderValue` stays in place for inline-GLSL
shaders (shader_uniforms.zig and friends).  The two paths coexist
during S1.3-S1.5; the engine eventually picks one as canonical in
S1.5.

**Test criteria**:
- End-to-end fixture: `tests/fixture.fs.zig` compiles via pipeline;
  emitted `.glsl` contains `#version 300 es` AND a UBO declaration
  (`layout(std140) uniform Uniforms { ... };`)
- Reflection check: `spirv-cross --reflect` lists the UBO under
  `ubos:` with the expected field names
- New shadermath helpers have unit tests
- New math.zig additions tested for parity with shadermath equivalents
- Std140 layout validation: a test fixture with a deliberately-
  misaligned struct produces the expected compile error
- Lint + tests green

**Scope**: ~300 LOC build.zig + ~200 LOC shadermath.zig + ~100 LOC
math.zig additions + ~150 LOC UBO host machinery.  Single session,
possibly 1.5.

### S1.3 — Migrate mandelbrot (proof of concept, redirected to UBO)

`examples/mandelbrot.fs.zig` already exists from the earlier
attempt but uses the rejected (§0.4) individual-uniform shape and
produces dangling-reference GLSL.  Rewrite to the UBO shape:

```zig
const sm = @import("shadermath");

const Uniforms = extern struct {
    center: sm.Vec2,
    zoom: f32,
    _pad0: f32 = 0,
    resolution: sm.Vec2,
    max_iter: f32,
    _pad1: f32 = 0,
};
extern const u: Uniforms addrspace(.uniform);

extern const frag_tex_coord: sm.Vec2 addrspace(.input);
extern var out_color: sm.Vec addrspace(.output);

export fn main() callconv(.spirv_fragment) void {
    sm.location(&out_color, 0);
    sm.binding(&u, 0, 0);   // descriptor set 0, binding 0

    const frag: sm.Vec2 = frag_tex_coord * u.resolution;
    const half_res: sm.Vec2 = u.resolution * sm.splat2(0.5);
    const scale: f32 = 4.0 / (u.zoom * u.resolution[1]);
    // ... iteration loop, coloring, write to out_color ...
}
```

Note the field names dropped their `u_` prefix — they're already
scoped inside `Uniforms` / `u.*`.  Engine-wide naming stays
snake_case (§0.5 still applies to the GLSL-visible UBO BLOCK
name `Uniforms`, not the inner fields).

`examples/mandelbrot.zig`: the four `getShaderLocation` +
`setShaderValue` calls collapse to one typed UBO push per frame:

```zig
const Uniforms = extern struct { ... };  // shared with .fs.zig

fn initState(...) !void {
    s.shader = try z.loadShaderFromMemory(f.gl, gpa, "", fs_source);
    s.ub = try z.createUniformBuffer(f.gl, Uniforms);
}

fn update(f: *z.Frame, s: *State) void {
    handleInput(f, s);
    z.pushUniforms(f.gl, s.ub, .{
        .center = s.center,
        .zoom = s.zoom,
        .resolution = .{ @floatFromInt(sw), @floatFromInt(sh) },
        .max_iter = MAX_ITERATIONS,
    });
    z.beginShaderMode(f.gl, s.shader);
    z.bindUniforms(f.gl, s.shader, s.ub, 0);  // binding 0
    z.drawRectangle(...);
    z.endShaderMode(f.gl);
}
```

(Shared `Uniforms` struct: the .fs.zig and .zig both define it.
S1.7's typed API auto-generates the host-side copy from the
.fs.zig AST so only one source of truth exists.  Until then,
keeping them in sync manually is the temporary state.)

**Test criteria**:
- Standalone HTML built; phone-tested.
- Visual: Mandelbrot fractal at center (-0.5, 0.0), iterating
  correctly, smooth color gradient, pan/zoom interactivity works.
- Reflection check: `spirv-cross --reflect` lists the UBO with
  the expected field names + offsets.
- Generated GLSL contains `layout(std140) uniform Uniforms { ... };`
  at top — verified by a grep step in the build.
- No console errors.
- Wasm size delta < +5 KB.
- Lint + tests green.

**Scope**: rewrite of existing `.fs.zig` (~70 LOC) + small host-side
change in `mandelbrot.zig` (~15 LOC swap) + reused S1.2 build wiring.
Single session.

### S1.4 — Migrate remaining math-only examples

`shader_uniforms.zig` (FS only) + `instancing.zig` (VS + FS pair).
Same UBO pattern as S1.3 — each gets its own `Uniforms` struct,
binding 0 by convention until multi-UBO designs surface.

The instancing migration is the first vertex shader through the
pipeline — verifies `callconv(.spirv_vertex)` + `position_out` +
multi-attribute vertex inputs (mat4 instance attr at location 8).
The per-instance transform is a vertex *attribute*, not a uniform,
so it's not in the UBO — confirms that the UBO + attribute split
works correctly together.

**Test criteria**: both standalone HTMLs render correctly on
phone, reflection lists the expected UBO + attributes, generated
GLSL contains the UBO declaration.  Lint + tests green.

**Scope**: 2 examples, each 1-2 shader files.  Single session.

### S1.4.5 — Sampler/texture investigation

**Step 1 (`addrspace(.constant)` for arbitrary uniforms) — DONE,
WORKS.**  A `u32` / `f32` / `zm.Vec2` extern declared with
`addrspace(.constant)` produces SPIR-V storage class
`UniformConstant`, which spirv-cross renders as a plain GLSL ES
loose uniform.  Reflection clean, spirv-val passes after
spirv-opt.  Bonus discovery: the engine's `view`/`projection`/
`mvp` push (currently inline-GLSL + `setShaderValue`) can migrate
to `extern const matX: zm.Mat addrspace(.constant);` style
without needing a UBO around it.  Loose-uniform binding is also
natural for the raylib-parity `SHADER_LOC_*` table.

**Step 2 (sampler-typed extern) — investigation paused; tractable
next sub-arc.**  Zig has no source-level type that maps to
`OpTypeSampledImage`.  `opaque {}` trips "cannot generate opaque
type" when passed through generic inline-asm helpers;
`extern struct {}` compiles but emits an empty-struct SPIR-V
type, not a sampled-image type.

The clear path forward is to splice the type + variable + sample
operation entirely via inline SPIR-V asm — building a `Sampler2D`
shadermath helper that wraps `OpTypeImage` + `OpTypeSampledImage`
+ `OpImageSampleImplicitLod` in asm strings.  Scope estimate
1-2 sessions once we sit down to it; deferred to a focused
S1.4.5b arc, low-priority but on the radar.  Should land before
S1.5 batch 2 (texture-using engine shaders) so that batch can
migrate via the DSL rather than staying inline GLSL.

**Interim state**: sampler-free shaders go through the pipeline
unaffected.  S1.5 batch 1 (no-texture engine shaders) is unblocked
and can start immediately; batch 2 waits on S1.4.5b.

### S1.5 — Migrate engine shaders (UBO-shaped)

Batch 1 unblocked now (sampler-free); batch 2 depends on S1.4.5b
(sampler DSL).  Create `src/shaders/` directory.
Each shader gets its own `Uniforms` UBO struct following the
S1.3 mandelbrot pattern.  Migrate in batches:

- **Batch 1 (no textures)**: `default_vs.zig`,
  `default_vs_skinned.zig`, `pbr_vs.zig`, `shadow_vs.zig`,
  `shadow_fs.zig`, `skybox_vs.zig`.  Each gets a Uniforms UBO
  containing the per-frame transforms (view/projection/etc.) plus
  per-draw data (model matrix, lighting params, etc.).
- **Batch 2 (textures)**: `default_fs.zig`, `skybox_fs.zig`.  UBO
  for the math, `UniformConstant`-decorated samplers for the
  textures (S1.4.5 machinery).
- **Batch 3 (the big one)**: `pbr_fs.zig` — 167 LOC + 8 samplers.
  Likely two UBOs here: scene constants (view/lights) and material
  parameters, to match the natural binding-frequency split.

Engine source files (`rlgl.zig`, `render.zig`) delete their inline
GLSL strings; engine shader-load calls do `@embedFile("default-vs")`
and use the typed loader from S1.2 (single UBO push per frame
instead of N `setShaderValue` calls).

Audit `SKYBOX_VS`/`SKYBOX_FS` in `drawing.zig` vs `skybox_*_source`
in `render.zig` — resolve dupe-or-drift as part of this batch.

**Test criteria** per migrated shader: visual parity, no console
errors, reflection lists the expected UBO(s) + samplers, lint +
tests green.  PBR especially: test scenes with lighting + shadows
must look pixel-identical to the pre-migration baseline.

**Scope**: 3-5 turns split by batch.

### S1.6 — Shader style guide + lint step

`src/notes/shader-style.md` — transcribe §4 gotchas plus any
discoveries from S1.3-S1.5.

`zig build lint-shaders` — scans `examples/*.fs.zig` +
`examples/*.vs.zig` + `src/shaders/*.zig` for forbidden patterns
(`bool` type, `inline fn`, missing `callconv`).

**Scope**: docs + small build step.  Single session.

### S1.7 — Typed Zig API from `.fs.zig` AST parsing

Parse the original `.fs.zig` source with `std.zig.Ast` to extract
uniform declarations; codegen a typed wrapper module per shader.

**Why source-parse, not `spirv-cross --reflect`** (decision turn
of-tutorial-discussion):

The `.fs.zig` source IS the spec.  The `Uniforms` extern struct
that gets `extern const u: Uniforms addrspace(.uniform);` declares
both the field names and their types in one place — we wrote it,
we should read it.  Going through spirv-cross --reflect adds a
JSON parser + a 4th tool just to recover information already
present in the source.  Also: `std.zig.Ast` machinery is already
in zimr (the linter uses it), so adding one more AST walk is cheap.

Trade-off accepted: if `spirv-opt` dead-strips an unused field,
the typed wrapper still declares it but the GPU-side UBO doesn't
have it.  Today that's a silent no-op; with the typed API we can
detect-and-warn at load time ("Uniforms.foo declared but not
present in compiled shader") via a reflection cross-check at build
time.  Net safety improvement either way.

**Build-step shape (UBO-native)**:

```
*.fs.zig
    │
    │  std.zig.Ast.parse → extract `const Uniforms = extern struct { ... };`
    │                       declaration block
    │
    ▼
*.fs.uniforms.zig (generated — re-exports the struct so the host
                    side can `@import("mandelbrot.fs")` and read it
                    without parsing the .fs.zig itself)
    │
    │  + the *.fs.glsl from the existing pipeline
    │
    ▼
*.fs (generated wrapper module)
    pub const Uniforms = extern struct { ... };  // mirror of the GPU-side
    pub const source = "<glsl>";
    pub const Loaded = struct {
        shader: Shader,
        ub: UniformBuffer(Uniforms),
        pub fn set(self: *Loaded, gl, u: Uniforms) void { ... }
    };
    pub fn load(gl, gpa) !Loaded { ... }
```

**Call-site shape**:

```zig
// build.zig
b.addShaderImport(exe, b.path("examples/mandelbrot.fs.zig"), "mandelbrot.fs");

// examples/mandelbrot.zig
const ms = @import("mandelbrot.fs");
// ...
var sh = try ms.load(f.gl, gpa);
sh.set(f.gl, .{
    .center = state.center,           // typed: must be Vec2
    .zoom = state.zoom,                // typed: must be f32
    .resolution = .{ sw_f, sh_f },     // typed: must be Vec2
    .max_iter = MAX_ITERATIONS,        // typed: must be f32
});
// One UBO push.  No per-uniform setter calls.
z.beginShaderMode(f.gl, sh.shader);
z.bindUniforms(f.gl, sh.shader, sh.ub, 0);
z.drawRectangle(...);
z.endShaderMode(f.gl);
```

Three bug categories closed by this:
1. **Typo in field name**: `.zooom = ...` is a Zig compile error.
2. **Wrong field type**: `.zoom = state.center` errors (Vec2 vs f32).
3. **Missing field**: omitting `.zoom` from the struct literal
   errors (no default).  Used to be a silent zero-init at load.

Plus the **single source of truth** win: the Uniforms struct only
exists in the .fs.zig file; the host imports its mirror.  No
manual sync between mandelbrot.fs.zig and mandelbrot.zig.

**Implementation deliverables**:
1. `tools/parse_shader_uniforms.zig` — AST walk extracting the
   `Uniforms` extern struct decl from the .fs.zig source.  Verifies
   it has a matching `extern const u: Uniforms addrspace(.uniform)`
   declaration.  ~50 LOC.
2. `tools/codegen_shader_module.zig` — template that takes the
   extracted struct + the GLSL string + writes the wrapper .zig
   (re-exporting `Uniforms` and providing the `Loaded` struct +
   `load` fn).  ~100 LOC.
3. `addShaderImport` in zimr's main build.zig grows to call
   both, registering the resulting module via `addAnonymousImport`.
4. `src/shader_uniform_buffer.zig` — runtime `UniformBuffer(T)`
   type wrapping the UBO machinery from S1.2.  Already exists by
   this point; S1.7 just adds the typed wrapper.
5. Migrate `examples/mandelbrot.zig` as the proof of concept.
6. Migrate remaining examples + engine shaders as a follow-up
   turn (S1.7b).

**Scope**: ~250-300 LOC total across build + runtime + migration.
Single session (maybe 1.5).

## 2. Turn dependency graph

```
S0 (rename pre-pass)                                       ✅
   │
S1.1 (vendor tools)                                        ✅
   │
S1.2 (build helper + shadermath.zig + math.zig parity      ✅
       + UBO host machinery)
   │
S1.3 (mandelbrot — UBO-shaped rewrite)                     ✅
   │
S1.4 (shader_uniforms + instancing — UBO)                  ⏸ partial
   │     (shader_uniforms ✅, instancing folds into S1.5)
   │
S1.4.5 (sampler investigation)                             ⏸ partial
   │     (step 1 done: `.constant` works; step 2 deferred
   │      to S1.4.5b inline-asm sub-arc)
   │
   ├─→ S1.5 batch 1 (engine shaders no textures)            ⏸ next
   │   │
   │   S1.4.5b (sampler inline-asm DSL) ─→ S1.5 batch 2 (texture engine shaders)
   │                                          │
S1.6 (style guide + lint-shaders) ────────────┤            ⏸ partial
S1.7 (typed wrappers — UBO-native API) ───────┘
```

S0 and S1.6 can run anytime; everything else is linear.

## 3. Open follow-ups (post-S1.7)

Not in scope for the migration arc:
- WGSL output (one-line `--target` change in spirv-cross — the
  natural path to WebGPU; UBOs already match WebGPU's uniform model
  so the shader side is mostly free)
- Cross-compile shader-tool binaries to Windows
- Comptime GLSL validator as belt-and-suspenders
- Native Zig SPIRV-Cross replacement (20-45 turn project; revisit
  only if vendored C++ maintenance becomes painful)
- Multi-UBO designs for the engine batching different
  binding-frequencies (per-frame, per-pass, per-material, per-draw)
  — useful for the engine shader work in S1.5 if profiling shows
  a single UBO's update cost is meaningful.

## 4. Appendix A — gotchas / findings from PoC

These shaped the design.  Will be transcribed into
`shader-style.md` in S1.6.

1. **`-fno-llvm -fno-lld`** mandatory.  Default LLVM segfaults
   on spirv targets in Zig 0.16.
2. **`callconv(.spirv_fragment)` / `.spirv_vertex`** triggers
   `OpEntryPoint` emission.  Without it spirv-cross fails with
   "no entry point in the SPIR-V module."
3. **`addrspace(.uniform|.input|.output)`** on `extern var/const`
   tags interface variables (modern API; replaces older
   `linksection(".spirv.*")`).
4. **No `bool`** — Zig codegens it as `u1` → spirv-cross emits
   `uint8_t` → requires WebGL2-unavailable int8 extension.  Use
   `u32` flags.
5. **Wrapping arithmetic** (`+%`, `-%`, `*%`) — otherwise Zig
   emits overflow checks as `OpIAddCarry` struct packs.
6. **`-O ReleaseFast`** to avoid debug safety checks.
7. **`std.gpu` in 0.16 ships built-ins but NOT decoration
   helpers**.  Declare `location`/`binding` locally via inline
   asm.
8. **Use `spirv-opt -O` (preset), not granular
   `--eliminate-dead-*`**.  Preset runs dead-branch-elim →
   merge-return → inline → dead-strip in correct order.
   Without inlining, every DSL helper survives as a separate
   function in the GLSL output.
9. **Inline-asm operand names leak as SPIR-V debug names.**
   `[ptr] "" (ptr)` makes SSA name `ptr` overwrite the
   variable's real name in output GLSL.  Use a placeholder
   like `target`.
10. **No `pub inline fn` in shader DSL helpers.**  Zig's SPIR-V
    backend emits structured-control-flow markers that bake in
    as `if (X == X)` constant branches.  Use plain `pub fn` and
    let `spirv-opt -O` inline at SPIR-V level.
11. **Uniform without UBO is a dead-reference fail.**  Declaring
    `extern const u_x: T addrspace(.uniform);` (individual, not in
    a buffer block) emits SPIR-V storage class `Uniform` — which
    spirv-cross treats as a UBO interior member.  Since the var
    isn't wrapped in a buffer block, the emitted GLSL references
    `u_x` in the body but never declares it.  WebGL2 then rejects
    the shader with `'u_x': undeclared identifier`.
    Evidence trail (this session):
    - `spirv-cross --reflect` on the .opt.spv: zero ubos, zero
      uniforms.  The names DO exist as OpName debug strings inside
      the SPIR-V binary (found at byte offsets 356-440), so the
      decls are emitted but in a storage class that spirv-cross
      can't reconcile with GLSL's loose-uniform shape.
    - The GLSL body has `u_x = ...` references but the file lacks
      any `uniform vec2 u_x;` declaration at top.
    Fix: declare uniforms inside an `extern struct` and bind it as
    a UBO (§0.4).  Avoid forcing SPIR-V storage class
    `UniformConstant` for arbitrary uniforms — even if you can get
    Zig to emit it, Vulkan disallows initializers on that storage
    class, and WebGPU has no equivalent at all.

## 5. Status board

- ✅ Pipeline verified end-to-end on mandelbrot + shader_uniforms
  with UBO-shaped uniforms.  Both render correctly; reflection
  shows the expected UBO blocks; spirv-val passes after opt.
- ✅ SPIRV-Cross builds via zig cc (Linux + Windows)
- ✅ Type vocabulary locked (§0.2)
- ✅ API parity strategy locked (§0.3)
- ✅ **Uniform style locked: UBO blocks (§0.4)** — reversal from
  earlier individual-extern plan after the dead-reference fail
- ✅ Uniform naming locked: snake_case (§0.5)
- ✅ File layout locked: sibling for examples, dir for engine (§0.6)
- ✅ Default VS locked: empty-string convention until S1.5 (§0.7)
- ✅ Sampler support (§0.8) — step 1 of S1.4.5 done:
  `addrspace(.constant)` works for arbitrary non-opaque uniforms,
  producing valid GLSL ES loose uniforms.  Step 2 (sampler types)
  pending S1.4.5b inline-asm sub-arc; texture-using shaders stay
  inline GLSL in the interim.
- ✅ Forward-compat strategy for `@Vector` proposal #32032 locked
  (§0.9): helpers stay thin, literals over constructors, layout
  arg adopted later via alias edit
- ✅ **S0 done** — engine-wide rename complete, tests 1864/1864,
  lint 0 issues, 4 example standalones rebuild + render correctly
- ✅ **S1.1 done** — SPIRV-Tools (v2026.2 hard-fork from tiawl)
  + SPIRV-Cross vendored under `tools/spirv/`.  Binaries build
  via `cd tools && zig build`.  Both smoke-tested + end-to-end
  pipeline verified on mandelbrot.fs.spv.  No .zon deps; no
  upstream tracking.
  - **Prebuilt-binaries workflow added** (turn — see PLAN.md):
    stripped Linux x86_64 binaries committed at
    `tools/spirv-prebuilt-linux-x86_64/` (9.1 MB total).
    `./tools/use-prebuilt-spirv.sh` stages them into
    `tools/zig-out/bin/`, skipping the ~12-min cold build on
    Linux sandbox restarts.  Windows builds from source as before.
- ✅ **S1.2 done** — `UniformBuffer(T)` typed wrapper +
  `bindBufferBase`/`getUniformBlockIndex`/`uniformBlockBinding`
  GL bridge.  Comptime asserts on layout (extern struct,
  16-byte-multiple size).  `shadermath` gained `square`, `atan2`,
  `clamp` re-export, pi/tau/euler/phi constants; `square` mirrored
  in math.zig.
- ✅ **S1.3 done** — mandelbrot migrated to UBO shape; single
  `ub.push(.{ ... })` per frame replaces 4× `setShaderValue`.
- ⏸ **S1.4 partial** — `shader_uniforms.zig` migrated (FS only,
  through the pipeline with a UBO).  `instancing.zig` migration
  blocked on engine `view`/`projection` uniform path; folds into
  S1.5 batch 1.
- ⏸ **S1.4.5 partial** — step 1 done (`addrspace(.constant)`
  works for non-opaque uniforms; bonus discovery for engine
  matrix-uniform migration).  Step 2 (sampler DSL via inline asm)
  deferred to S1.4.5b sub-arc; 1-2 session estimate.
- ⏸ **S1.5 batch 1 in flight** — `default_vs.zig` migrated +
  **visually verified rendering**.  Confirms a key piece of the
  pipeline shape:
    - Zig 0.16 has no source construct that emits `OpTypeMatrix`,
      so `[4]Vec` (== `zm.Mat`) flows through as `OpTypeArray
      vec4 4` and spirv-cross emits `uniform vec4 mvp[4];`
      instead of `uniform mat4 mvp;`.
    - `glUniformMatrix4fv` accepts the `vec4[4]`-shaped uniform
      anyway — WebGL2's type check is permissive enough at the
      API edge, and the column-major memory layout is identical
      to `mat4`.  No post-processing of the GLSL needed.
    - Body math is identical: `mvp[i].x` is valid syntax for
      both `mat4` and `vec4[4]`, so no source-level adjustments
      either.
  Batch 1 progress:
    - ✅ `default_vs` — visually verified with cube3d (the wasm
      that doesn't draw any vertices like `basic` is NOT a valid
      verification — must reload an actual-geometry example).
    - ✅ `shadow_vs` — visually verified via `models3d` standalone.
    - ✅ `shadow_fs` — visually verified via `models3d` standalone.
    - ✅ `skybox_vs` — visually verified via `skybox` standalone.
    - ✅ `pbr_vs` — built clean, `rewriteMatUniforms` verified
      in the wasm bytes for all 5 mat4 uniforms (mat_model,
      mat_view, mat_projection, mat_normal, light_space_matrix).
      Visual verify via `pbr_demo` standalone pending.
    - `pbr_fs` — **blocked on S1.4.5b** (samplers for albedo /
      normal / metallic-roughness / shadow map).
    - `default_vs_skinned` — pending; gnarly because
      `bone_matrices[60]` is an array of mat4 (60 × vec4[4]) and
      `rewriteMatUniforms` only handles single mat4 uniforms today;
      needs extension for the array case.
    - `default_fs` (DEFAULT_FRAGMENT_SHADER in rlgl.zig:2049)
      — **blocked on S1.4.5b** (uses `sampler2D texture0`).

  Infrastructure landed in this batch:
    - `src/shader_post.zig`: `rewriteMatUniforms(comptime raw,
      comptime names)` does comptime text rewrite
      `uniform vec4 N[4];` → `uniform mat4 N;` at each `@embedFile`
      site.  Workaround for Zig 0.16 having no `OpTypeMatrix`.
    - `shadermath`: gained `mulMatVec(m, v)` and `mulMatPoint(m, p)`
      (column-major mat-vec, matches GLSL `m * v`).  Replaces
      ~15 lines of per-shader splat-and-sum boilerplate.
    - `build.zig`: engine shaders are now AUTO-DISCOVERED.
      `collectShaderFiles` walks `src/`/`examples/`/`tests/` for
      `_vs.zig` / `_fs.zig` files; the engine loop filters to
      `src/shaders/` and registers each as an `@embedFile`-able
      import on `zimr_mod` + `zimr_mod_smoke`.  Drop a new
      `<name>_vs.zig` / `<name>_fs.zig` in `src/shaders/` and it
      gets picked up — zero build.zig edits needed.
    - File-naming retired: `.vs.zig` / `.fs.zig` dot-form is gone;
      all shader sources use `_vs.zig` / `_fs.zig` (host
      `@embedFile("<name>.glsl")` correspondingly).  Lint
      allowlist + ZLS-introspection module list both follow this.
    - ZLS go-to-definition on `zm.X` from inside shader files:
      build.zig adds shadow `b.addModule("shader_zls:<path>", ...)`
      registrations per shader file with `shadermath` in their
      `.imports`.  Same `collectShaderFiles` walk powers this.
- ⏸ S1.5 batch 2 (texture-using engine shaders) — waits on S1.4.5b.
- ⏸ **S1.6 partial** — `src/notes/shader-style.md` written
  (consolidated do/don't reference covering everything discovered
  through S1.3-S1.4).  `lint-shaders` step: two checks landed in
  `lint_zimr` (`shader-inline-fn`, `shader-no-atan`) that fire
  automatically on `.fs.zig` / `.vs.zig` files — no separate build
  step needed; surfaces in regular `zig build lint`.  More rules
  can join as patterns emerge.
- ⏸ S1.7 typed wrappers — not yet started.
