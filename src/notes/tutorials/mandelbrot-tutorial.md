# Tutorial — Mandelbrot, end-to-end

A walkthrough of how a non-trivial shader in zimr is structured today,
including the build pipeline, the typed-iface single-source-of-truth
pattern, and the compile-error messages you'll see when interfaces
drift.

The Mandelbrot example was chosen because it's the simplest case that
uses a **Uniform Buffer Object (UBO)** for its per-frame parameters,
which is the place where CPU↔shader struct drift used to be possible.
It also pairs a custom fragment shader with the engine's *default*
vertex shader — so it exercises the "shader varyings flow between two
separate compilation units" path.

---

## 1. Files involved

Five source files plus two build-generated files:

| File | Hand-edited? | Role |
|---|---|---|
| `examples/mandelbrot_fs_iface.zig` | yes (source of truth) | Typed schema: Inputs, Outputs, Ubo struct |
| `examples/mandelbrot_fs.zig` | yes | SPIR-V shader body |
| `examples/mandelbrot.zig` | yes | CPU host code |
| `examples/assets/fonts/atkinson_mono.ttf` | yes | HUD font, not shader-related |
| _(any other example assets)_ | yes | |
| `.zig-cache/.../extern.zig` | **generated** | Codegen output for the shader |
| `.zig-cache/.../shader.glsl` | **generated** | Final GLSL, `@embedFile`d by CPU |

The iface is the *only* place the UBO layout is human-written. Both
the shader body and the CPU side derive their view of `Ubo` from this
one declaration.

---

## 2. The interface (`mandelbrot_fs_iface.zig`)

Three sections, each playing a distinct role:

```zig
// examples/mandelbrot_fs_iface.zig

const zm = @import("shadermath");

/// Varying inputs from the engine default VS.  Field names + order
/// MUST match `src/shaders/default_common_iface.zig`'s `Interp` (a
/// rename there breaks the GLSL link here — not silent corruption,
/// but worth keeping aligned).
pub const Inputs = struct {
    frag_tex_coord: zm.Vec2,
    frag_color: zm.Vec,
};

/// Stage output — the rendered fractal colour.
pub const Outputs = struct {
    out_color: zm.Vec,
};

/// UBO layout.  std140 alignment rules: vec2 needs 8-byte alignment,
/// the whole block must round to vec4 (16-byte) alignment.  Explicit
/// `_padN` fields enforce the right offsets — the comptime check in
/// `UniformBuffer(T)` catches "forgot trailing pad" drift via
/// `@sizeOf(T) % 16 == 0`.
pub const Ubo = extern struct {
    center: zm.Vec2,
    zoom: f32,
    _pad0: f32 = 0,
    resolution: zm.Vec2,
    max_iter: f32,
    _pad1: f32 = 0,
};
```

The iface file `@import("shadermath")`s for the `Vec2` / `Vec` type
aliases — `zm.Vec2` is exactly `@Vector(2, f32)`, just less noisy in
schema declarations.  The build wires `shadermath` as a named module
to every iface compile alongside `shader_interface`; unused-import
elision means schemas that don't reference shadermath types pay zero
cost.

### `Inputs` / `Outputs`

These are read by `tools/gen_shader_externs.zig` (the codegen library)
and turned into `pub extern const X: T addrspace(.input);` /
`pub extern var X: T addrspace(.output);` declarations in the
generated `extern.zig`. Field order matters — the codegen assigns
`layout(location = N)` decorations by index.

For the Mandelbrot, **`Inputs` field names must match the engine
default VS's `Outputs`**. The GLSL linker pairs varyings by name. If
you rename `frag_tex_coord` here, the linker silently produces a
shader where the FS sees zero for that varying — a rendering bug,
not a compile error. (One of the only "interfaces" zimr can't
statically check today; documented in the iface file's doc comment.)

### `Ubo`

This is the *uniform buffer block*. `extern struct` gives it C-ABI
layout, and the explicit `_pad0` / `_pad1` fields enforce the std140
offset rules that GLSL UBOs require:

- A `vec2` (`@Vector(2, f32)`) needs 8-byte alignment.
- The whole block must round up to 16-byte alignment.

The codegen reflects on this struct and **emits an identical
declaration** into the shader's `extern.zig`. CPU host code imports
this file directly. Both sides see the same fields, in the same
order, with the same offsets — by construction.

---

## 3. The shader body (`mandelbrot_fs.zig`)

```zig
const zm = @import("shadermath");
const io = @import("io");

fn hsv2rgb(c: zm.Vec3) zm.Vec3 {
    // ... HSV → RGB helper, ~12 lines ...
}

export fn main() callconv(.spirv_fragment) void {
    io.setup();
    _ = io.frag_color; // engine sets it, but mandelbrot's colour is purely computed

    // Pixel → complex plane.
    const frag: zm.Vec2 = io.frag_tex_coord * io.u.resolution;
    const half_res: zm.Vec2 = zm.vec2(io.u.resolution[0] * 0.5, io.u.resolution[1] * 0.5);
    const scale: f32 = 4.0 / (io.u.zoom * io.u.resolution[1]);
    const c: zm.Vec2 = zm.vec2(
        io.u.center[0] + (frag[0] - half_res[0]) * scale,
        io.u.center[1] - (frag[1] - half_res[1]) * scale,
    );

    // z_{n+1} = z_n² + c.
    var z: zm.Vec2 = zm.vec2(0, 0);
    var n: f32 = 0;
    var escaped: u32 = 0;
    var i: u32 = 0;
    while (i < 1024) : (i +%= 1) {
        if (@as(f32, @floatFromInt(i)) >= io.u.max_iter) break;
        const x2: f32 = zm.square(z[0]);
        const y2: f32 = zm.square(z[1]);
        if (x2 + y2 > 256.0) { escaped = 1; break; }
        z = zm.vec2(x2 - y2 + c[0], 2.0 * z[0] * z[1] + c[1]);
        n += 1.0;
    }

    if (escaped == 0) {
        io.out_color = zm.vec4(0, 0, 0, 1);
    } else {
        const mod_z: f32 = @sqrt(zm.square(z[0]) + zm.square(z[1]));
        const nu: f32 = zm.log2(zm.log2(mod_z));
        const smoothed: f32 = n + 1.0 - nu;
        const t: f32 = smoothed / io.u.max_iter;
        const col: zm.Vec3 = hsv2rgb(zm.vec3(0.85 + 0.4 * t, 0.7, zm.pow(t, 0.4)));
        io.out_color = zm.vec4(col[0], col[1], col[2], 1.0);
    }
}
```

Two imports:

- **`shadermath`** — the math helpers (`zm.vec2`, `zm.dot`, `zm.normalize`,
  `zm.square`, ...). These are zimr's `pub fn`s that compile cleanly
  through SPIR-V.
- **`io`** — the codegen output. Every external symbol the shader
  uses lives here: `io.frag_tex_coord`, `io.out_color`, `io.u`, etc.
  The shader body never hand-writes an `extern` declaration. For
  shaders with samplers, codegen also emits accessor methods
  (`io.texture0(uv)`) so the shader reads as "fetch from texture0 at
  uv" instead of passing sampler handles around.

The first line of `main` — `io.setup()` — is a codegen-emitted
helper that bundles every required `OpDecorate Location` and
`OpDecorate DescriptorSet/Binding` call into one function. Before
this existed, every shader's `main` opened with 2-6 lines of
`zm.location(&io.foo, io._location_foo);` boilerplate that the
codegen already knew about. `noinline` keeps the call shape stable
through spirv-opt; the wrapper has zero output-size cost (it inlines
fully into the optimized SPIR-V).

The body uses `io.u.center` / `io.u.zoom` / `io.u.max_iter` /
`io.u.resolution` — these are *fields* of the UBO struct, not loose
uniforms. The shader sees them as members of a single GLSL UBO block
(see the generated GLSL below).

---

## 4. The CPU side (`mandelbrot.zig`)

The relevant bits, with everything else (HUD, input handling, etc.)
elided:

```zig
const std = @import("std");
const z = @import("zimr");

const fs_source = @embedFile("mandelbrot_fs.glsl");

// Typed shader interface — single source of truth for the UBO layout.
// The shader body sees the same struct via codegen (`io.Ubo`); both
// sides cannot drift because there is only one human-edited
// declaration (in `mandelbrot_fs_iface.zig`).  `UniformBuffer(T)`
// still enforces `@sizeOf(T) % 16 == 0` at comptime as a safety net
// for the std140 trailing-pad requirement.
const iface = @import("mandelbrot_fs_iface.zig");
const Ub = z.UniformBuffer(iface.Ubo);

const INITIAL_CENTER: z.math.Vec2 = .{ -0.5, 0.0 };

const State = struct {
    // ...
    center: z.math.Vec2 = INITIAL_CENTER,
    zoom: f32 = INITIAL_ZOOM,
    dragging: bool = false,
    drag_anchor_world: z.math.Vec2 = .{ 0, 0 },
    // ...
};

// ... in initState ...
const shader: z.Shader = try z.loadShaderFromMemory(f.gl, gpa, "", fs_source);
const ub: Ub = Ub.create(.{
    .center = INITIAL_CENTER,
    .zoom = INITIAL_ZOOM,
    .resolution = .{ sw_f, sh_f },
    .max_iter = MAX_ITERATIONS,
}, 0);
try ub.attach(shader.id, "extern_Ubo");

// ... in update, per frame ...
s.ub.push(.{
    .center = s.center,
    .zoom = s.zoom,
    .resolution = .{ @floatFromInt(sw), @floatFromInt(sh) },
    .max_iter = MAX_ITERATIONS,
});
```

Four things to notice:

1. **`const iface = @import("mandelbrot_fs_iface.zig")`** — direct
   relative import of the iface file. The CPU module has the
   `shader_interface` and `shadermath` named modules available, so
   the iface file resolves cleanly even if it references either.
2. **`z.UniformBuffer(iface.Ubo)`** — `Ub` is a struct type
   parametrized on the UBO layout. The body of `UniformBuffer(T)` does
   `@sizeOf(T) % 16 == 0` at comptime; that's the safety net for the
   std140 trailing-pad requirement.
3. **`z.math.Vec2` everywhere** — CPU state, function signatures, and
   the push struct literals all use the vec alias. No `[2]f32` /
   `@Vector(2, f32)` mixing, no coercion at call sites. Vec arithmetic
   on the CPU side is the same syntax as on the shader side
   (`s.center += world_before - world_after`).
4. **`ub.attach(shader.id, "extern_Ubo")`** — bind the UBO buffer to
   the GLSL block named `"extern_Ubo"`. The name is what `spirv-cross`
   synthesises from the codegen module name (`extern.zig` →
   `extern_Ubo`). This *is* a string-named binding — one of the few
   places in the typed pipeline where a string still has to match
   something downstream. Could be tightened in future by surfacing
   the block name through the iface, but for now it's a single string
   per shader.

The CPU's UBO writes happen through anonymous struct literals
(`.{ .center = ..., .zoom = ..., ... }`) which Zig type-checks against
`iface.Ubo`. Missing fields, misspelled fields, or wrong-shape values
all produce compile errors — see the error catalog in §6.

---

## 5. The build pipeline

`build.zig` auto-discovers `examples/<name>_<purpose>_{vs,fs}.zig`
shader files for each example, plus sibling `_iface.zig` files for
typed-iface schemas. No `build.zig` edit needed when you add a new
shader.

For Mandelbrot, the pipeline runs roughly:

```
examples/mandelbrot_fs.zig        (hand-written shader body)
examples/mandelbrot_fs_iface.zig  (hand-written schema)
        │
        ├─► Stage 0 (codegen): a tiny bootstrap exe imports the iface
        │   and calls `tools/gen_shader_externs.emit(iface, writer)`.
        │   Writes to `extern.zig` in the build cache.
        │
        │   For mandelbrot, the output looks like:
        │
        │       // AUTO-GENERATED — do not edit.
        │       pub extern const frag_tex_coord: @Vector(2, f32) addrspace(.input);
        │       pub const _location_frag_tex_coord: u32 = 0;
        │       pub extern const frag_color: @Vector(4, f32) addrspace(.input);
        │       pub const _location_frag_color: u32 = 1;
        │       pub extern var out_color: @Vector(4, f32) addrspace(.output);
        │       pub const _location_out_color: u32 = 0;
        │       pub const Ubo = extern struct {
        │           center: @Vector(2, f32),
        │           zoom: f32,
        │           _pad0: f32,
        │           resolution: @Vector(2, f32),
        │           max_iter: f32,
        │           _pad1: f32,
        │       };
        │       pub extern const u: Ubo addrspace(.uniform);
        │       pub const _binding_u: u32 = 0;
        │
        │   The codegen emits `@Vector(N, f32)` here regardless of
        │   whether the iface used `zm.Vec2` or `@Vector(2, f32)` —
        │   they're the same type at the @typeInfo level.  The
        │   generated file is intentionally dependency-free so the
        │   shader body's compile doesn't have to drag shadermath in
        │   through this path.
        │
        ▼
Stage 1 (SPIR-V): `zig build-obj -target spirv32-vulkan` with the
shader body as root + `io.zig` as the `io` module dependency.
Produces raw SPIR-V binary.
        │
        ▼
Stage 2a (zspv --rewrite-samplers): post-processes SPIR-V to convert
sampler placeholder externs to real `OpTypeSampledImage` samplers.
No-op for shaders without samplers (like mandelbrot).
        │
        ▼
Stage 2b (spirv-opt -O): inlines, dedupes, strips, etc.
        │
        ▼
Stage 3 (spirv-val): safety net — verify the SPIR-V is well-formed.
        │
        ▼
Stage 4 (spirv-cross --version 300 --es): SPIR-V → GLSL ES 3.0.
Synthesises the UBO block name `extern_Ubo` from the module name.
        │
        ▼
Stage 5: post-processing.  Strips Int8 extension lines, rewrites
loose mat4-shaped vec4[4] uniforms back to mat4, etc.
        │
        ▼
.zig-cache/.../shader.glsl
```

The final GLSL for mandelbrot looks like this:

```glsl
#version 300 es
precision mediump float;
precision highp int;

layout(std140) uniform extern_Ubo
{
    highp vec2 center;
    highp float zoom;
    highp float _pad0;
    highp vec2 resolution;
    highp float max_iter;
    highp float _pad1;
} u;

layout(location = 0) out highp vec4 out_color;
in highp vec2 frag_tex_coord;

void main()
{
    // ~50 lines of mostly-loop-unrolled GLSL implementing the
    // Mandelbrot iteration + smooth coloring.
}
```

This is what gets `@embedFile`'d back into the CPU module and
compiled into a shader program at runtime.

The `examples/mandelbrot.zig` CPU side does the rest:

- Build a `z.Shader` from the empty VS source (which falls back to
  the engine default VS) and the embedded FS source.
- Create a `UniformBuffer(iface.Ubo)` seeded with the initial view.
- Bind that buffer to the GLSL block `extern_Ubo`.
- Each frame: push the current view state via `ub.push(.{...})` and
  draw a full-canvas rectangle through the shader.

---

## 6. Error catalog — what happens when the interface drifts

Each section below shows ONE deliberate break and the exact compile
error it produces. All errors are caught at `zig build`-time; nothing
reaches the GPU in a broken state.

### Error 1 — Rename a field in the iface (`zoom` → `zooom`)

The iface declared a field one way, but the shader body still refers
to the old name.

**Edit:** `examples/mandelbrot_fs_iface.zig`:
```zig
pub const Ubo = extern struct {
    center: @Vector(2, f32),
    zooom: f32,                  // typo!
    _pad0: f32 = 0,
    // ...
};
```

**Error from `zig build`:**
```
examples/mandelbrot_fs.zig:65:37: error: no field named 'zoom' in struct 'extern.Ubo'
.zig-cache/o/115a68d031f535cc585991ac90e7a738/extern.zig:17:24: note: struct declared here
```

The shader body references `io.u.zoom`. The codegen-emitted `io.Ubo`
no longer has a `zoom` field — and Zig's struct-field-access checker
catches it at the shader-body compile.

### Error 2 — Typo in shader body field access

The iface is fine; the body refers to a non-existent field.

**Edit:** `examples/mandelbrot_fs.zig`:
```zig
const c: zm.Vec2 = zm.vec2(
    io.u.centerr[0] + (frag[0] - half_res[0]) * scale,  // typo!
    io.u.center[1] - (frag[1] - half_res[1]) * scale,
);
```

**Error:**
```
examples/mandelbrot_fs.zig:67:15: error: no field named 'centerr' in struct 'extern.Ubo'
.zig-cache/o/08da9bfed212cfb1c4d42df773784967/extern.zig:17:24: note: struct declared here
```

Same machinery as Error 1, just caught from the other direction.

### Error 3 — Typo on CPU side

The iface is fine; the CPU's anonymous struct literal at the push
site refers to a non-existent field.

**Edit:** `examples/mandelbrot.zig`:
```zig
s.ub.push(.{
    .centerr = .{ s.center[0], s.center[1] },   // typo!
    .zoom = s.zoom,
    .resolution = .{ @floatFromInt(sw), @floatFromInt(sh) },
    .max_iter = MAX_ITERATIONS,
});
```

**Error:**
```
examples/mandelbrot.zig:194:10: error: no field named 'centerr' in struct 'mandelbrot_fs_iface.Ubo'
examples/mandelbrot_fs_iface.zig:50:24: note: struct declared here
```

This time the "note" points back to the iface's `Ubo` declaration —
because `iface.Ubo` is what the CPU's struct literal is checked
against. Both shader and CPU sides ultimately point back to the same
iface file when something goes wrong; just one through the
codegen-emitted copy, the other through the direct import.

### Error 4 — Forgot a required field on the CPU push

The iface declares `max_iter`. The push site forgets to set it.

**Edit:** `examples/mandelbrot.zig`:
```zig
s.ub.push(.{
    .center = .{ s.center[0], s.center[1] },
    .zoom = s.zoom,
    .resolution = .{ @floatFromInt(sw), @floatFromInt(sh) },
    // max_iter missing
});
```

**Error:**
```
examples/mandelbrot.zig:193:16: error: missing struct field: max_iter
examples/mandelbrot_fs_iface.zig:50:24: note: struct declared here
```

Zig requires every non-defaulted field to be set in an anonymous
struct literal. `max_iter` has no default → must be present.

(The `_pad0` and `_pad1` fields have `= 0` defaults so they can be
omitted from the push literal, as you'd expect — they're plumbing,
not values.)

### Error 5 — Wrong type in iface (`zoom: f32` → `zoom: i32`)

The iface declares a type one way; the shader body uses it as a
different type.

**Edit:** `examples/mandelbrot_fs_iface.zig`:
```zig
pub const Ubo = extern struct {
    center: @Vector(2, f32),
    zoom: i32,                  // changed from f32
    _pad0: f32 = 0,
    // ...
};
```

**Error:**
```
examples/mandelbrot_fs.zig:65:42: error: incompatible types: 'i32' and 'f32'
examples/mandelbrot_fs.zig:65:36: note: type 'i32' here
examples/mandelbrot_fs.zig:65:60: note: type 'f32' here
```

This points at the body's arithmetic site (`io.u.zoom * io.u.resolution[1]`),
where `i32 * f32` is rejected. Different from the field-rename errors
(which fire at field-access time) — Zig catches the type mismatch
when the body tries to use the value in math.

### Error 6 — Forget std140 trailing pad (size not a multiple of 16)

The iface struct's total size violates std140's "block size must be
a multiple of 16 bytes" rule.

**Edit:** `examples/mandelbrot_fs_iface.zig`:
```zig
pub const Ubo = extern struct {
    center: @Vector(2, f32),
    zoom: f32,
    _pad0: f32 = 0,
    resolution: @Vector(2, f32),
    max_iter: f32,
    one_extra: f32 = 0,
    two_extra: f32 = 0,
    // _pad1 removed; total size = 40 bytes, not a multiple of 16
};
```

**Error:**
```
src/uniform_buffer.zig:57:13: error: UniformBuffer(T): @sizeOf(mandelbrot_fs_iface.Ubo) is 40, must be a multiple of 16 (std140) — add trailing pad fields
examples/mandelbrot.zig:82:27: note: called at comptime here
```

`UniformBuffer(T)`'s comptime check fires. The error message includes
the exact computed size (`40`) and points at the call site
(`z.UniformBuffer(iface.Ubo)`). Add a trailing `_padN: f32 = 0` to
round up to the next multiple of 16.

### Error 7 — Rename an Inputs varying (`frag_tex_coord` → `frag_uv`)

The iface renames a varying. The shader body still uses the old name.

**Edit:** `examples/mandelbrot_fs_iface.zig`:
```zig
pub const Inputs = struct {
    frag_uv: @Vector(2, f32),       // renamed from frag_tex_coord
    frag_color: @Vector(4, f32),
};
```

**Error:**
```
examples/mandelbrot_fs.zig:63:30: error: root source file struct 'extern' has no member named 'frag_tex_coord'
.zig-cache/o/b57ff0ffd84c745c238d3e461f67158d/extern.zig:5:1: note: struct declared here
```

Codegen regenerates `extern.zig` without `frag_tex_coord` (the field
is now `frag_uv`); the body's `io.frag_tex_coord` resolves nowhere.

**Important caveat:** the "iface↔engine-default-VS" interface is *not*
statically checked. If you rename `frag_tex_coord` to `frag_uv` in
this iface but DON'T rename it in `src/shaders/default_common_iface.zig`,
the build will succeed but the GLSL linker will silently fail to match
the two varyings — and your fragment shader will see zero for
`frag_uv`. This is a documented limitation; the iface file's doc
comment calls it out.

### Error 8 — Wrong vector shape at CPU push

The iface declares `center: @Vector(2, f32)`. The CPU literal passes
a 3-element value.

**Edit:** `examples/mandelbrot.zig`:
```zig
s.ub.push(.{
    .center = .{ s.center[0], s.center[1], 0 },  // 3 elements!
    .zoom = s.zoom,
    .resolution = .{ @floatFromInt(sw), @floatFromInt(sh) },
    .max_iter = MAX_ITERATIONS,
});
```

**Error:**
```
examples/mandelbrot.zig:194:20: error: expected 2 vector elements; found 3
```

Zig's anonymous-struct-literal coercion to `@Vector(2, f32)` catches
the shape mismatch.

---

## 7. What is **not** caught statically

Two categories of mistakes still slip through:

1. **Varying-name mismatch between paired shaders.** If you rename
   `frag_tex_coord` in `mandelbrot_fs_iface.zig`'s `Inputs` but leave
   it as `frag_tex_coord` in `src/shaders/default_common_iface.zig`'s
   `Interp` (which the engine default VS uses), the build succeeds
   but the GLSL linker silently leaves the FS's `frag_tex_coord` (or
   whatever you renamed it to) unbound. The FS sees zero for that
   varying. This is the only "interface" zimr doesn't currently
   structurally check.

2. **Subtle std140 offset bugs.** The `@sizeOf(T) % 16 == 0` check
   catches the most common failure (missing trailing pad). It does
   NOT catch e.g. a missing `_pad` between a `f32` and a following
   `vec2`. If you write:
   ```zig
   pub const Ubo = extern struct {
       a: f32,
       b: @Vector(2, f32),  // SHOULD have a 4-byte pad before this
       _pad0: f32 = 0,
   };
   ```
   ...the struct is 16 bytes (multiple of 16), passes the check, but
   Zig's `extern struct` correctly auto-pads to 8-byte align for `b`,
   so the layout is actually right. The opposite case (Zig disagrees
   with std140) is rare with `@Vector(N, f32)` field types — if you
   want belt-and-braces verification, run `spirv-cross --reflect` and
   compare the offsets to `@offsetOf(Ubo, fieldname)`.

---

## 8. The "before" picture (and why we fixed it)

Before the iface-as-source-of-truth migration, the two declarations
of `Uniforms` were independent:

```zig
// mandelbrot_fs.zig (shader side):
const Uniforms = extern struct {
    center: zm.Vec2,
    zoom: f32,
    _pad0: f32 = 0,
    resolution: zm.Vec2,
    max_iter: f32,
    _pad1: f32 = 0,
};

// mandelbrot.zig (CPU side):
const Uniforms = extern struct {
    center: [2]f32,
    zoom: f32,
    _pad0: f32 = 0,
    resolution: [2]f32,
    max_iter: f32,
    _pad1: f32 = 0,
};
```

These had to be manually kept in sync. The comment on the CPU side
said "Field order + padding here MUST match" — but nothing checked it.
Adding a `rogue_field: [2]f32` to one side and not the other built
clean; the shader read 8 bytes of garbage as its `max_iter` value.
The CPU side used `[2]f32` while the shader used `zm.Vec2` — not just
duplicated, but in *different* types that happened to have the same
binary layout.

The fix replaces both declarations with a single one in the iface
file (using `zm.Vec2` throughout — the CPU side now uses `z.math.Vec2`
in its State too, so types match end-to-end and CPU push sites take
the vec directly). The shader sees its copy via codegen; the CPU sees
the original via direct `@import`. Drift between them is structurally
impossible — the only way to "drift" is to edit the iface file, which
propagates the change to both sides simultaneously, which is the
correct behavior.

---

## 9. Try it yourself

```bash
# Build everything
zig build

# Run the mandelbrot standalone (produces a single .html file)
python3 scripts/build_standalone.py mandelbrot
# Open prebuilt/standalone/mandelbrot.html in a browser.

# Try one of the breaks from §6 — e.g.
sed -i 's/zoom: f32,/zooom: f32,/' examples/mandelbrot_fs_iface.zig
zig build  # error.

# Restore
git checkout examples/mandelbrot_fs_iface.zig
```
