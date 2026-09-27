# zig-shader-tutorial.md — writing shaders in Zig, end-to-end

Written turn-of-S1.1.  Companion to `zig-shader-pipeline-plan.md`.
Where the plan says "what we're building and why", this says
"what it looks like to use it."  Read this when:

- You're authoring a new shader and want a template to start from.
- You're migrating a GLSL string-literal shader to a `.fs.zig` file.
- You hit a SPIR-V compile error and need to know which Zig pattern
  to use instead.
- You want to know how uniforms, attributes, samplers, etc. work
  in this dialect.

Examples here use the end-state API (S1.2-S1.5 lands the pieces).
The tutorial is the spec; if the code disagrees, the code is wrong.

---

## 0. The 30-second pitch

You write shaders as `.fs.zig` and `.vs.zig` files.  The build
pipeline turns them into GLSL ES 3.0 strings that get baked into
your wasm via `@embedFile`.  At runtime, zimr loads them like any
raylib shader:

```zig
const fs_source = @embedFile("mandelbrot.fs.glsl");
const shader = try z.loadShaderFromMemory(gl, gpa, "", fs_source);
```

You get:
- **Type safety**: the compiler catches `f32 + Vec2` at edit time.
- **Tooling**: `zls`, `zig fmt`, syntax highlighting, jump-to-def.
- **No more silent string typos**: a misspelled `texture0` in a
  `\\uniform sampler2D texturE0;` line used to fall through to a
  default shader and render pink.  Now it's a Zig compile error.
- **Shared code with the CPU**: a `lerp` function defined once,
  callable from a tween on the CPU and a colour mix on the GPU.
- **One language to think in**.

You give up:
- Inline shader source in your example file (now next door instead).
- The ability to recompile shaders without a `zig build`.
- A small slice of GLSL features (no `discard;` syntax — `return;`
  works; no `#define` — `comptime` does it better).

---

## 1. The pipeline at a glance

```
mandelbrot.fs.zig
    │
    │  zig build-obj -target spirv32-vulkan -ofmt=spirv
    │      -mcpu vulkan_v1_2 -fno-llvm -fno-lld -O ReleaseFast
    ▼
mandelbrot.fs.spv          raw SPIR-V, may have dead std-imports
    │
    │  spirv-opt -O --skip-validation
    ▼
mandelbrot.fs.opt.spv      dead-stripped, valid SPIR-V
    │
    │  spirv-val             ← safety net: build fails on bad shaders
    │
    │  spirv-cross --version 300 --es
    ▼
mandelbrot.fs.glsl         GLSL ES 3.0 — what WebGL2 wants
    │
    │  @embedFile via b.addShader → b.addAnonymousImport
    ▼
baked into your wasm
```

All four tools live in `tools/zig-out/bin/`: `spirv-opt`,
`spirv-val`, `spirv-cross`, all built from vendored source by
`cd tools && zig build`.  See `src/notes/changelogs/changelog360-369.md`
under S1.1 if you're curious about the vendoring.

The `--skip-validation` on `spirv-opt` is deliberate: Zig 0.16's
SPIR-V backend emits a dead `Target_Cpu` struct from std-imports
that the v2026.2 validator (correctly) rejects.  `spirv-opt -O`
dead-strips it on its very next pass; we run `spirv-val` AFTER
opt to get back the safety net.

---

## 2. Your first shader

Here's the smallest useful fragment shader.  Solid magenta:

```zig
// examples/magenta.fs.zig
const sm = @import("zimr").shadermath;

export fn main() callconv(.spirv_fragment) void {
    out_color = sm.vec4(1, 0, 1, 1);
}

extern var out_color: sm.Vec addrspace(.output);
```

Three things to notice:

1. **`callconv(.spirv_fragment)`** on `main` — this is what tells
   the Zig backend to emit `OpEntryPoint Fragment %main` instead
   of a CPU calling convention.  The equivalent for a vertex
   shader is `.spirv_vertex`.

2. **`extern var out_color: Vec addrspace(.output)`** — outputs
   are extern variables in the `.output` address space.  The
   declaration must be `extern` (no value), and the type must be
   `Vec` (which is `@Vector(4, f32)` — see §4).

3. **`@import("zimr").shadermath`** — `shadermath.zig` is zimr's
   GPU-side math + shader-DSL module.  It mirrors `math.zig`'s
   API but adds GPU-only types (`Vec3`) and decorators
   (`location`, `binding`).

Use it from a CPU file like any other shader:

```zig
// examples/magenta.zig
const std = @import("std");
const z = @import("zimr");

const magenta_fs = @embedFile("magenta.fs.glsl");

pub fn frame(f: *z.Frame) !void {
    const gpa = std.heap.smp_allocator;
    const state = f.state(State);
    if (state.shader.id == 0) {
        state.shader = try z.loadShaderFromMemory(f.gl, gpa, "", magenta_fs);
    }
    z.beginShaderMode(state.shader);
    z.drawRectangle(f.gl, ..., 0, 0, 200, 200, z.colors.white);
    z.endShaderMode(state.shader);
}
```

The `""` for the vertex shader argument means "use the engine
default" (a passthrough that hands fragment coords + tex coords
to the fragment stage).  After S1.5 the engine default is itself
a `.vs.zig` file but the empty-string convention stays as a
convenience.

**That's it.** The build emits `magenta.fs.glsl` automatically
when you wire it up in `build.zig`:

```zig
// build.zig
const magenta_fs = b.addShader(b.path("examples/magenta.fs.zig"));
exe.root_module.addAnonymousImport("magenta.fs.glsl", .{
    .root_source_file = magenta_fs,
});
```

The `addShader` helper runs the four-stage pipeline above; the
generated `.glsl` is embedded via the `@embedFile` lookup.

---

## 3. The shadermath module

Before more examples, the type vocabulary.  Open `src/shadermath.zig`
and you'll find these:

```zig
// Core types
pub const Vec  = @Vector(4, f32);   // also in math.zig
pub const Vec2 = @Vector(2, f32);   // also in math.zig
pub const Vec3 = @Vector(3, f32);   // GPU only — CPU uses Vec
pub const Mat  = [4]Vec;            // 4x4 matrix

// Builders — GLSL-spelled.  No 3-arg `vec(x, y, z)` here: that
// name in math.zig is the homogeneous-direction constructor
// (sets w=0), which is a different shape from what shader code
// wants.
pub fn vec2(x: f32, y: f32) Vec2                  { ... }
pub fn vec3(x: f32, y: f32, z: f32) Vec3          { ... }
pub fn vec4(a: f32, b: f32, c: f32, d: f32) Vec   { ... }
```

`Vec` is `@Vector(4, f32)` — same on CPU and GPU, one canonical name.
There is no `Vec4`.

`Vec3` is GPU-only because on the CPU you typically want SIMD-aligned
4-component vectors with a wasted `w` slot for speed; on the GPU
3-component vectors are a real distinct type from 4-comp (`vec3` vs
`vec4` in GLSL).

### 3.1 Swizzling

```zig
const v: sm.Vec = sm.vec4(1, 2, 3, 4);
const x = sm.x(v);             // 1.0
const yz = sm.sw(v, "yz");     // Vec2{2, 3}
const wzyx = sm.sw(v, "wzyx"); // Vec{4, 3, 2, 1}
```

The single-component swizzles `x`/`y`/`z`/`w` return `f32`.
The general-purpose `sw(v, "abc...")` returns a vector with one
component per character in the swizzle string.  String length 2
gives `Vec2`, length 3 gives `Vec3`, length 4 gives `Vec`.  String
contents are validated at comptime.

The implementation is `@shuffle` under the hood — same code on
both sides of the `math.zig` / `shadermath.zig` line for the
`sw` multi-component form, so a swizzle on the CPU is
bit-identical to the same swizzle on the GPU.

**One asymmetry**: `math.zig` does NOT have the single-component
`x`/`y`/`z`/`w` helpers (only `sw`).  Reason: those names would
shadow ~24 local `const x: f32 = ...` bindings in vendored zmath
code.  In code shared between CPU and GPU (e.g. a palette function),
use direct index access `v[0]` / `v[1]` / etc. — idiomatic Zig,
works on both sides.  The named helpers exist in `shadermath.zig`
only because there's no clash in a GPU-side file.

### 3.2 Scalar helpers

These exist in both `math.zig` and `shadermath.zig` with identical
signatures and behaviour:

```zig
pub fn clamp01(x: f32) f32 { ... }       // max(0, min(1, x))
pub fn mix(a: f32, b: f32, t: f32) f32 { ... }
pub fn pow(x: f32, e: f32) f32 { ... }
pub fn log2(x: f32) f32 { ... }
pub fn fract(x: f32) f32 { ... }         // x - floor(x)
pub fn smoothstep(e0: f32, e1: f32, x: f32) f32 { ... }
pub fn step(edge: f32, x: f32) f32 { ... }  // 0 if x < edge else 1
```

`mix` is GLSL's name; `math.zig` re-exports `lerp` from zmath as
the alias.  Either works on the CPU side.

### 3.3 Vector helpers

```zig
pub fn dot(a: anytype, b: @TypeOf(a)) f32 { ... }
pub fn length(v: anytype) f32 { ... }
pub fn distance(a: anytype, b: @TypeOf(a)) f32 { ... }
pub fn normalize(v: anytype) @TypeOf(v) { ... }
```

These are generic over the vector type — pass a `Vec2`, get f32 back.
Pass a `Vec3` or `Vec`, same thing.

On the CPU side, `math.zig` ALSO has `dot3`/`length3`/`normalize3`
that take a `Vec` (4-comp) but operate as if it were 3-comp.  Those
exist because `math.zig` doesn't have `Vec3` — they're the workaround.
On the GPU side they don't exist because `Vec3` is real there.

### 3.4 GPU-only decorators

Two functions that don't exist in `math.zig`:

```zig
pub fn location(comptime ptr: anytype, comptime n: u32) void { ... }
pub fn binding(
    comptime ptr: anytype,
    comptime set: u32,
    comptime bind: u32,
) void { ... }
```

These wrap inline SPIR-V `OpDecorate` instructions.  Call them
from inside the entry-point function with a *pointer* to the
extern variable being decorated (`&out_color`, not `out_color`).
Example coming up in §6.

---

## 4. A real example — mandelbrot

The classic.  Math-only, uses uniforms, demonstrates the loop
pattern.

```zig
// examples/mandelbrot.fs.zig
const sm = @import("zimr").shadermath;

// Inputs (varyings from the vertex stage)
extern const frag_tex_coord: sm.Vec2 addrspace(.input);
extern const frag_color: sm.Vec addrspace(.input);

// Outputs
extern var out_color: sm.Vec addrspace(.output);

// Uniforms
extern const u_center: sm.Vec2 addrspace(.uniform);
extern const u_zoom: f32 addrspace(.uniform);
extern const u_resolution: sm.Vec2 addrspace(.uniform);
extern const u_max_iter: f32 addrspace(.uniform);

export fn main() callconv(.spirv_fragment) void {
    const frag = frag_tex_coord * u_resolution;
    const c = u_center + (frag - sm.vec2(0.5, 0.5) * u_resolution) * 4.0
              / (u_zoom * sm.y(u_resolution));

    var z = sm.vec2(0, 0);
    var i: u32 = 0;
    const max_iter_u: u32 = @intFromFloat(u_max_iter);

    while (i < max_iter_u) : (i +%= 1) {
        const x2 = sm.x(z) * sm.x(z);
        const y2 = sm.y(z) * sm.y(z);
        if (x2 + y2 > 4.0) break;
        z = sm.vec2(x2 - y2 + sm.x(c), 2.0 * sm.x(z) * sm.y(z) + sm.y(c));
    }

    if (i == max_iter_u) {
        out_color = sm.vec4(0, 0, 0, 1);
    } else {
        const smoothed = @as(f32, @floatFromInt(i)) + 1.0 - sm.log2(sm.log2(sm.length(z)));
        const t = smoothed / u_max_iter;
        // Palette: sin-based rainbow
        const r = 0.5 + 0.5 * @sin(3.0 + 6.28318 * t);
        const g = 0.5 + 0.5 * @sin(1.0 + 6.28318 * t);
        const b = 0.5 + 0.5 * @sin(5.0 + 6.28318 * t);
        out_color = sm.vec4(r, g, b, 1.0);
    }
}
```

A few things worth pointing out:

- **No `bool` anywhere.**  `(x2 + y2 > 4.0)` returns `bool` in
  source but the comparison's result is consumed by the `if`
  branch directly — never stored in a variable.  Why?  Because
  Zig codegens stored `bool` as `u1`, which spirv-cross then
  emits as `uint8_t` — needing a GLSL extension WebGL2 doesn't
  ship.  See §9 for the workaround when you really need a flag.

- **`i +%= 1`** (wrapping add), not `i += 1`.  Same reason:
  regular `+=` generates `OpIAddCarry` which packs a result struct
  spirv-cross can't lower to GLSL ES 3.0.  Use the wrapping
  operators (`+%`, `-%`, `*%`) in shader code.

- **No `pub inline fn`.**  Helper functions are fine — declare
  them `pub fn` and let `spirv-opt` inline.  An `inline fn` makes
  the Zig backend emit `if (X == X)` constant-condition branches
  as structured-control-flow markers, which spirv-cross dutifully
  preserves as GLSL noise.

The CPU side is unchanged from the pre-Zig-shader era:

```zig
// examples/mandelbrot.zig
const mandelbrot_fs = @embedFile("mandelbrot.fs.glsl");

const State = struct {
    shader: z.Shader = .{},
    loc_center: i32 = 0,
    loc_zoom: i32 = 0,
    loc_resolution: i32 = 0,
    loc_max_iter: i32 = 0,
    // ...
};

fn loadShader(f: *z.Frame, state: *State) !void {
    state.shader = try z.loadShaderFromMemory(f.gl, gpa, "", mandelbrot_fs);
    state.loc_center     = z.getShaderLocation(state.shader, "u_center");
    state.loc_zoom       = z.getShaderLocation(state.shader, "u_zoom");
    state.loc_resolution = z.getShaderLocation(state.shader, "u_resolution");
    state.loc_max_iter   = z.getShaderLocation(state.shader, "u_max_iter");
}

fn perFrame(state: *State) void {
    z.setShaderValue(state.shader, state.loc_center,     &state.center, .vec2);
    z.setShaderValue(state.shader, state.loc_zoom,       &state.zoom, .float);
    z.setShaderValue(state.shader, state.loc_resolution, &state.res, .vec2);
    z.setShaderValue(state.shader, state.loc_max_iter,   &state.iter, .float);
}
```

The uniform names in `getShaderLocation` strings match the
`extern const` names in the shader source.  Spelling-check by
the compiler: if you misspell `u_zoom` in the .fs.zig, the build
fails at SPIR-V emission, not at WebGL runtime.

But the spelling-check on the **CPU side** (`getShaderLocation`
strings) is still loose — a typo in the CPU's `"u_zoom"` lookup
gets you a silent runtime no-op, not a build error.  S1.7 closes
this with build-step codegen of typed wrappers; the end-state
for the above will be:

```zig
// build.zig
b.addShaderImport(exe, b.path("examples/mandelbrot.fs.zig"), "mandelbrot.fs");

// examples/mandelbrot.zig
const ms = @import("mandelbrot.fs");

const State = struct {
    sh: ms.Loaded = undefined,
    center: Vec2 = .{ -0.5, 0 },
    zoom: f32 = 1.0,
    // ...
};

fn loadShader(f: *z.Frame, state: *State) !void {
    state.sh = try ms.load(f.gl, gpa);
}

fn perFrame(state: *State) void {
    state.sh.u_center.set(state.center);   // typed: takes Vec2
    state.sh.u_zoom.set(state.zoom);       // typed: takes f32
    state.sh.u_zooom.set(...);             // Zig compile error: no such field
    state.sh.u_zoom.set(state.center);     // Zig compile error: type mismatch
    state.sh.flush();                       // batches the glUniform calls
}
```

How: the build step parses the `.fs.zig` source with `std.zig.Ast`,
extracts the `extern const u_*: T addrspace(.uniform)` lines, and
emits a wrapper module (`mandelbrot.fs`) that bundles the GLSL
string with typed setter fields.  No `spirv-cross --reflect`, no
JSON — the `.fs.zig` source IS the spec, so we read the spec
directly.  Two classes of bug closed: typo'd uniform names (Zig
compile error instead of `getShaderLocation = -1`) and wrong
value type (Zig compile error instead of `glUniform3fv` reading
off the end of a `Vec2`).

---

## 5. Vertex shaders

Vertex shaders use `callconv(.spirv_vertex)` and have a special
output: `gl_Position`.  The Zig spelling is:

```zig
extern var gl_position: sm.Vec addrspace(.output);
```

A minimal pass-through vertex shader for instanced rendering:

```zig
// examples/instancing.vs.zig
const sm = @import("zimr").shadermath;

// Per-vertex attributes (locations 0+1 are raylib conventions)
extern const vertex_position: sm.Vec3 addrspace(.input);
extern const vertex_tex_coord: sm.Vec2 addrspace(.input);

// Per-instance attribute at location 8 (mat4 occupies 8..11)
extern const instance_transform: sm.Mat addrspace(.input);

// Outputs to fragment stage
extern var frag_tex_coord: sm.Vec2 addrspace(.output);
extern var frag_color: sm.Vec addrspace(.output);
extern var gl_position: sm.Vec addrspace(.output);

// Uniforms
extern const view: sm.Mat addrspace(.uniform);
extern const projection: sm.Mat addrspace(.uniform);

export fn main() callconv(.spirv_vertex) void {
    sm.location(&vertex_position, 0);
    sm.location(&vertex_tex_coord, 1);
    sm.location(&instance_transform, 8);

    frag_tex_coord = vertex_tex_coord;
    const world_pos = instance_transform * sm.vec4(
        sm.x(vertex_position), sm.y(vertex_position), sm.z(vertex_position), 1.0,
    );
    // Per-vertex colour from world position
    frag_color = sm.vec4(
        0.5 + 0.5 * @sin(sm.x(world_pos) * 0.5),
        0.5 + 0.5 * @sin(sm.y(world_pos) * 0.5),
        0.5 + 0.5 * @sin(sm.z(world_pos) * 0.5),
        1.0,
    );
    gl_position = projection * view * world_pos;
}
```

Two new things:

1. **`sm.location(&attr, n)` calls at top of `main`** set explicit attribute
   locations.  Without this, the SPIR-V backend auto-assigns and
   raylib's `getShaderLocation` for `vertex_position` would
   probably not match location 0.  Set them explicitly — match the
   raylib attribute layout (positions in `RL_DEFAULT_SHADER_ATTRIB_LOCATION_*`).

2. **`instance_transform: Mat`** at location 8 is a single mat4
   attribute that occupies locations 8, 9, 10, 11 (one per
   column).  GLSL maps this automatically; the Zig declaration
   stays as one symbol.  This matches raylib's instancing
   convention.

Pair with the matching fragment shader:

```zig
// examples/instancing.fs.zig
const sm = @import("zimr").shadermath;

extern const frag_tex_coord: sm.Vec2 addrspace(.input);
extern const frag_color: sm.Vec addrspace(.input);

extern var out_color: sm.Vec addrspace(.output);

extern const col_diffuse: sm.Vec addrspace(.uniform);

export fn main() callconv(.spirv_fragment) void {
    _ = frag_tex_coord;  // unused — colour comes from VS
    out_color = frag_color * col_diffuse;
}
```

`col_diffuse` is one of raylib's stock per-material uniforms that
the engine sets automatically inside `beginBlendMode`.  As long
as you spell it `col_diffuse` you'll get its value for free.

---

## 6. Engine shaders & explicit layout

For engine-internal shaders (PBR, skybox, shadow), the file lives
in `src/shaders/` rather than `examples/`.  Bigger shaders also
tend to want explicit locations on more attributes to interop
cleanly with the raylib slot conventions.

Sketch of a PBR vertex shader header:

```zig
// src/shaders/pbr_vs.zig
const sm = @import("zimr").shadermath;

// raylib reserved attribute slots
extern const vertex_position:   sm.Vec3 addrspace(.input);  // loc 0
extern const vertex_tex_coord:  sm.Vec2 addrspace(.input);  // loc 1
extern const vertex_normal:     sm.Vec3 addrspace(.input);  // loc 2
extern const vertex_color:      sm.Vec  addrspace(.input);  // loc 3
extern const vertex_tangent:    sm.Vec  addrspace(.input);  // loc 4
extern const vertex_tex_coord2: sm.Vec2 addrspace(.input);  // loc 5

extern var frag_world_pos:        sm.Vec3 addrspace(.output);
extern var frag_world_normal:     sm.Vec3 addrspace(.output);
extern var frag_tex_coord:        sm.Vec2 addrspace(.output);
extern var frag_light_space_pos:  sm.Vec  addrspace(.output);
extern var gl_position:           sm.Vec  addrspace(.output);

extern const mat_model:            sm.Mat addrspace(.uniform);
extern const mat_view:             sm.Mat addrspace(.uniform);
extern const mat_projection:       sm.Mat addrspace(.uniform);
extern const mat_normal:           sm.Mat addrspace(.uniform);
extern const light_space_matrix:   sm.Mat addrspace(.uniform);

export fn main() callconv(.spirv_vertex) void {
    sm.location(&vertex_position,   0);
    sm.location(&vertex_tex_coord,  1);
    sm.location(&vertex_normal,     2);
    sm.location(&vertex_color,      3);
    sm.location(&vertex_tangent,    4);
    sm.location(&vertex_tex_coord2, 5);

    const world_pos = mat_model * sm.vec4(
        sm.x(vertex_position), sm.y(vertex_position), sm.z(vertex_position), 1.0,
    );
    frag_world_pos = sm.sw(world_pos, "xyz");
    frag_world_normal = sm.normalize(sm.sw(
        mat_normal * sm.vec4(sm.x(vertex_normal), sm.y(vertex_normal), sm.z(vertex_normal), 0.0),
        "xyz",
    ));
    frag_tex_coord = vertex_tex_coord;
    frag_light_space_pos = light_space_matrix * world_pos;
    gl_position = mat_projection * mat_view * world_pos;
}
```

The fragment side is much bigger because PBR involves a lot of
light math — see `src/shaders/pbr_fs.zig` for the real one.
Key feature: helper functions are first-class:

```zig
fn distributionGgx(n: sm.Vec3, h: sm.Vec3, roughness: f32) f32 {
    const a = roughness * roughness;
    const a2 = a * a;
    const n_dot_h = @max(sm.dot(n, h), 0);
    const denom = (n_dot_h * n_dot_h * (a2 - 1.0) + 1.0);
    return a2 / (3.14159265 * denom * denom);
}

fn geometrySchlickGgx(n_dot_v: f32, roughness: f32) f32 {
    const r = roughness + 1.0;
    const k = (r * r) / 8.0;
    return n_dot_v / (n_dot_v * (1.0 - k) + k);
}

// ...

export fn main() callconv(.spirv_fragment) void {
    // ... use distributionGgx, geometrySchlickGgx, etc.
}
```

Note these are `pub fn`, not `pub inline fn` — see §9 for why.

---

## 7. Build integration

The build helper has two flavours:

```zig
// In build.zig

// (a) Compile and return the .glsl LazyPath:
const fs_path: std.Build.LazyPath = b.addShader(b.path("examples/mandelbrot.fs.zig"));

// (b) Compile AND wire into an executable in one call:
b.addShaderImport(exe, b.path("examples/mandelbrot.fs.zig"), "mandelbrot.fs.glsl");
```

Form (a) returns the `LazyPath` of the generated GLSL; you can
do whatever with it.  Form (b) is shorthand for the common case:

```zig
const fs_path = b.addShader(b.path("examples/mandelbrot.fs.zig"));
exe.root_module.addAnonymousImport("mandelbrot.fs.glsl", .{
    .root_source_file = fs_path,
});
```

Then in your example's main file:

```zig
const fs = @embedFile("mandelbrot.fs.glsl");
```

There's a hand-wavy magic in how Zig's `@embedFile` ends up with
the LazyPath result — `addAnonymousImport` makes the build-cache
file appear as an "embed file" the module can reference by the
import name.  All builds of the example automatically get the
glsl re-generated when the .fs.zig source changes.

### 7.1 Smoke-checking GLSL output

For debugging, you can ask the build to keep intermediate files:

```bash
zig build install -Dfocus=mandelbrot -Dshader-debug
ls zig-out/shaders/
# mandelbrot.fs.spv
# mandelbrot.fs.opt.spv
# mandelbrot.fs.glsl
```

Reading `mandelbrot.fs.glsl` directly is a great way to verify
spirv-cross is producing what you expect.  Common things to
spot-check:

- `#version 300 es` on line 1
- `precision mediump float;` (or highp, depending on inputs)
- A UBO block named `*_Uniforms` containing your `u_*` declarations
- `in vec2 frag_tex_coord;` / `out vec4 out_color;` matching your
  extern declarations
- A `void main()` body that looks reasonable

If spirv-cross produces `uniform float u_foo;` instead of a UBO
block, that's fine and is just version-dependent.  If you see
`uniform sampler2D` declarations with no value, see §8.

---

## 8. Samplers and textures

> **Status note (S1.4.5 pending).**  Samplers in Zig-source shaders
> are an open investigation — Zig 0.16's `addrspace` enum has no
> `uniform_constant` variant, which is SPIR-V's storage class for
> samplers + images.  The patterns below are the likely end-state;
> they may shift slightly when S1.4.5 lands.

The expected API is via an opaque type + inline SPIR-V decorators:

```zig
// examples/chromatic.fs.zig
const sm = @import("zimr").shadermath;

extern const frag_tex_coord: sm.Vec2 addrspace(.input);
extern const frag_color:     sm.Vec  addrspace(.input);

extern var out_color: sm.Vec addrspace(.output);

// Samplers live in `.constant` address space with an opaque type.
extern const texture0: sm.Sampler2D addrspace(.constant);
extern const col_diffuse: sm.Vec addrspace(.uniform);
extern const u_offset: f32 addrspace(.uniform);
extern const u_time: f32 addrspace(.uniform);

export fn main() callconv(.spirv_fragment) void {
    sm.binding(&texture0, 0, 0);   // descriptor set 0, binding 0

    const t = 0.5 + 0.5 * @sin(u_time * 2.0);
    const o = u_offset * t;

    const r = sm.x(sm.sample(texture0, frag_tex_coord + sm.vec2(o, 0)));
    const g = sm.y(sm.sample(texture0, frag_tex_coord));
    const b = sm.z(sm.sample(texture0, frag_tex_coord - sm.vec2(o, 0)));

    out_color = sm.vec4(r, g, b, 1.0) * col_diffuse * frag_color;
}
```

Key shapes:

- **`sm.Sampler2D`** — an opaque type wrapping the SPIR-V
  `OpTypeImage` + `OpTypeSampledImage` types.  Other planned
  variants: `SamplerCube`, `Sampler3D`, `Sampler2DArray`,
  `Sampler2DShadow`.
- **`sm.sample(sampler, uv) → Vec`** — wraps
  `OpImageSampleImplicitLod`.  Returns `Vec` (RGBA).  There will
  also be `sm.sampleLod(sampler, uv, lod)` and similar variants.
- **`sm.binding(&target, set, binding)`** — like `location`, sets
  the SPIR-V descriptor set + binding number for the sampler.

CPU side is unchanged:

```zig
const loc_tex = z.getShaderLocation(state.shader, "texture0");
const loc_time = z.getShaderLocation(state.shader, "u_time");
const loc_offset = z.getShaderLocation(state.shader, "u_offset");
// ...
z.setShaderValueTexture(state.shader, loc_tex, state.texture);
z.setShaderValue(state.shader, loc_time, &time, .float);
```

If S1.4.5 finds `addrspace(.constant)` doesn't work, the fallback
plan is inline-asm declaration of sampler vars + sample calls.
The user-facing shape (`sm.Sampler2D`, `sm.sample`, etc.) stays
the same; only the implementation in shadermath.zig changes.

---

## 9. Common pitfalls

The Zig SPIR-V backend has rough edges.  These are the ones we've
hit; check `src/notes/shader-style.md` for the latest list.

### 9.1 No `bool` storage

```zig
// ✗ BAD — stored bool → u1 → spirv-cross emits uint8_t (extension required)
const is_negative = (x < 0);
if (is_negative) ...

// ✓ GOOD — inline the comparison
if (x < 0) ...

// ✓ GOOD when you need a flag — use u32
extern const u_enabled: u32 addrspace(.uniform);
if (u_enabled != 0) ...
```

Engine convention: flag uniforms are `u32`, set on the CPU via
`setShaderValue(..., &val, .int)`.

### 9.2 Wrapping integer arithmetic

```zig
// ✗ BAD — generates OpIAddCarry, which packs a {sum, carry} struct
//         that spirv-cross can't unpack to GLSL ES 3.0
i += 1;
i -= 1;
i *= 2;

// ✓ GOOD — wrapping operators codegen plain OpIAdd/OpISub/OpIMul
i +%= 1;
i -%= 1;
i *%= 2;
```

For shader loops where you know overflow can't happen anyway, this
is a free change.  Iteration counters, hash mixers, palette index
math — all fine.

### 9.3 Helper functions: `fn`, not `inline fn`

```zig
// ✗ BAD — emits dummy `if (X == X)` branches in the SPIR-V output
//         that spirv-cross preserves as GLSL noise
pub inline fn dot3(a: Vec3, b: Vec3) f32 {
    return sm.x(a)*sm.x(b) + sm.y(a)*sm.y(b) + sm.z(a)*sm.z(b);
}

// ✓ GOOD — let spirv-opt's inliner do the work post-codegen
pub fn dot3(a: Vec3, b: Vec3) f32 {
    return sm.x(a)*sm.x(b) + sm.y(a)*sm.y(b) + sm.z(a)*sm.z(b);
}
```

The `-O` preset's `inline_exhaustive_pass` will inline aggressively
at the SPIR-V level.  Trust it.

### 9.4 No debug-build shaders

`-O ReleaseFast` is mandatory in the pipeline.  Debug builds enable
runtime safety checks (bounds, integer overflow, etc.) — every one
of those gets emitted as conditional SPIR-V instructions that spirv-
cross dutifully translates to GLSL.  Result: shader bloat + invalid
GLSL because half the safety primitives don't exist on GPU.

The build helper passes `-O ReleaseFast` automatically; don't
override.

### 9.5 LLVM backend doesn't work for SPIR-V

```bash
# ✗ Fails — Zig's LLVM backend segfaults on spirv targets
zig build-obj -target spirv32-vulkan main.zig

# ✓ Works — disable both LLVM and LLD
zig build-obj -target spirv32-vulkan -fno-llvm -fno-lld main.zig
```

The build helper does this automatically.  Just don't try to
compile a .fs.zig manually without those flags and wonder why
nothing happens.

### 9.6 `std.gpu` is partial in Zig 0.16

The `std.gpu` namespace has built-in declarations (`gl_position`,
`gl_FragCoord`, etc.) and the `executionMode` builtin, but it's
missing the `location`/`binding` decorators we use heavily.
`shadermath.zig` provides those locally via inline SPIR-V asm.

When Zig 0.17 stabilizes those, we'll switch over and remove
shadermath's `location`/`binding` implementations.  The public
API stays the same.

### 9.7 Inline asm operand names leak as SPIR-V debug names

```zig
// ✗ BAD — the operand name "ptr" becomes the SPIR-V variable's
//         debug name, which then shows up in the GLSL output
asm volatile (
    \\OpDecorate %ptr Location 0
    : : [ptr] "" (target),
);

// ✓ GOOD — use a placeholder operand name
asm volatile (
    \\OpDecorate %target Location 0
    : : [target] "" (target),
);
```

`shadermath.zig`'s `location` and `binding` helpers already do
this.  You only hit this if you write your own inline-asm
decorators.

### 9.8 Samplers as struct fields — no

```zig
// ✗ BAD — Zig may emit a logical-pointer operand to %_struct_xxx
//         that spirv-cross can't lower
const Material = struct {
    diffuse: Sampler2D,
    normal: Sampler2D,
};
extern const material: Material addrspace(.constant);

// ✓ GOOD — flat, one per binding
extern const material_diffuse: Sampler2D addrspace(.constant);
extern const material_normal: Sampler2D addrspace(.constant);
```

Samplers want to be top-level externs.

---

## 10. CPU/GPU code sharing

Because `math.zig` and `shadermath.zig` mirror each other, a
function defined in shadermath can be called from CPU code too
(the implementations are pure-Zig and don't use SPIR-V intrinsics):

```zig
// In src/shadermath.zig:
pub fn rgbFromHue(h: f32) Vec3 {
    return vec3(
        0.5 + 0.5 * @sin(h),
        0.5 + 0.5 * @sin(h + 2.0944),
        0.5 + 0.5 * @sin(h + 4.1888),
    );
}
```

From a shader (`examples/spiral.fs.zig`):

```zig
const sm = @import("zimr").shadermath;
// ...
const col = sm.rgbFromHue(angle + u_time);
out_color = sm.vec4(sm.x(col), sm.y(col), sm.z(col), 1.0);
```

From the CPU (`examples/spiral.zig`):

```zig
const sm = @import("zimr").shadermath;
// ...
const hud_color = sm.rgbFromHue(state.angle);
z.drawRectangle(f.gl, ..., x, y, w, h, .{
    .r = @intFromFloat(sm.x(hud_color) * 255),
    .g = @intFromFloat(sm.y(hud_color) * 255),
    .b = @intFromFloat(sm.z(hud_color) * 255),
    .a = 255,
});
```

Same input, same output, same line of source.  This is mainly
useful for palette functions, animation easings, procedural
generators — anything where the CPU needs to render a UI
preview of what the shader will do.

---

## 11. Testing shaders

The build pipeline catches syntactically broken shaders (SPIR-V
emission fails) and structurally broken shaders (spirv-val fails
post-opt).  For shader correctness — does it produce the pixel
you wanted — the workflow is:

1. **Build a standalone HTML** of the example: `python3
   scripts/build_standalone.py mandelbrot`
2. **Open the HTML** in a browser (or phone via standalone HTML)
3. **Visual check**.  If the shader is broken, it usually renders
   solid pink (the engine's fallback for "shader compile failed")
   — open the JS console to see the GL error.
4. **For pixel-exact testing**, the rasterize-snapshot system
   in `src/tests/` (Tier 1 / Q-pillar from the imgui arc) can
   diff against a reference image.

The `tools/zig-out/bin/spirv-cross --version 300 --es` step is
your best friend for debugging — read the generated GLSL.  It
tells you exactly what the GPU is seeing.

---

## 12. Forward look

The end-state goal beyond S1.7 includes:

- **UBO blocks** (instead of individual extern uniforms) for
  shaders with many uniforms.  Reduces glUniform call count.
- **Compute shaders** (`callconv(.spirv_kernel)` + WebGPU target)
  for offline preprocess of e.g. mipmap generation.  WebGL2 has
  no compute, so wasm bundles get a wgsl/glsl fork.
- **Multi-target backends**: ship MSL for native Mac builds, HLSL
  for native Windows.  spirv-cross already supports all three;
  build.zig grows a `target=opengl_es|metal|d3d11` option.
- **Shader hot-reload** in dev builds: the dev server
  (`tools/serve.zig`) is static today, with no file watcher or
  reload; a watcher on `*_fs.zig`/`*_vs.zig` plus a re-run of the
  build pipeline and a page reload would give fast shader iteration.

None of those are in S1; they're horizon items.  S1's job is to
get the basic Zig → GLSL ES 3.0 pipeline working for every
shader the engine + examples currently ship.

---

## Appendix A — quick reference

### File naming

| file                                  | purpose                              |
|---------------------------------------|--------------------------------------|
| `examples/foo.zig`                    | example main + state + frame fn      |
| `examples/foo.fs.zig`                 | example fragment shader source       |
| `examples/foo.vs.zig`                 | example vertex shader (optional)     |
| `src/shaders/pbr_fs.zig`              | engine fragment shader               |
| `src/shaders/pbr_vs.zig`              | engine vertex shader                 |

### Declaration cheat sheet

```zig
const sm = @import("zimr").shadermath;

// Inputs (varyings + per-vertex attributes)
extern const name: T addrspace(.input);

// Outputs (varyings to next stage + gl_position + out_color)
extern var name: T addrspace(.output);

// Uniforms (set by CPU via setShaderValue)
extern const name: T addrspace(.uniform);

// Samplers (S1.4.5 — likely shape)
extern const name: sm.Sampler2D addrspace(.constant);

// Entry point
export fn main() callconv(.spirv_fragment) void { ... }
export fn main() callconv(.spirv_vertex) void { ... }

// Explicit layout (when needed) — call from inside main()
sm.location(&my_attribute, 0);
sm.binding(&my_sampler, 0, 1);
```

### Allowed types in shaders

| Zig                  | GLSL                | notes                            |
|----------------------|---------------------|----------------------------------|
| `f32`                | `float`             | yes                              |
| `u32`                | `uint`              | yes (use for flags, counters)    |
| `i32`                | `int`               | yes                              |
| `Vec2`               | `vec2`              | `@Vector(2, f32)`                |
| `Vec3`               | `vec3`              | `@Vector(3, f32)`, GPU-only      |
| `Vec`                | `vec4`              | `@Vector(4, f32)`                |
| `Mat`                | `mat4`              | `[4]Vec`                         |
| `[N]T`               | `T[N]`              | fixed-size arrays                |
| `Sampler2D` (opaque) | `sampler2D`         | S1.4.5                           |
| `bool` (NOT stored)  | bool (in expr only) | use `u32` for stored flags       |
| `f16`                | (none)              | needs extension WebGL2 lacks     |
| `i64`/`u64`          | (none)              | not available                    |
| Structs              | structs             | OK for varyings; avoid for unis  |
