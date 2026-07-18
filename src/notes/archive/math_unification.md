# math_unification.md — one math library, two targets

## TL;DR (the dream)

Today zimr has two math modules:
- **`src/math.zig`** — 6758 lines.  Host-only.  Row-major + `v*M`
  convention.  Tests, asserts, FFT, ray-tri intersection, splines,
  the works.  119 `pub fn`s.  Imported as `zm` in 41 source files.
- **`src/shadermath.zig`** — 447 lines.  SPIR-V-compatible.  Different
  nomenclature (column-major + `M*v`), but BYTE-COMPATIBLE with
  math.zig matrices because the two conventions are duals.  Imported
  as `zm` by every shader source file.

**Goal**: one module, `src/math.zig`, that compiles for ALL targets
(host x86_64/wasm32 AND SPIR-V).  Same names, same semantics, same
byte layouts.  A shader writes `const m = @import("math");` and
gets `Camera3D`, `Complex`, `lookAt`, `cross3`, `slerp`, `sdf.box`,
`sdf.union`, the lot.  A host file writes `const m = @import("math");`
and gets the same.

This is something no other engine has cleanly.  GLSL has built-in
`mat4`/`mix` — but no `Camera3D`, no rays, no complex numbers, no
SDF combinators.  HLSL/Slang/WGSL have host-shader splits but the
host language is C++/C# and the math libraries don't port.  Zig is
the first time the same source code can compile to SPIR-V AND
native AND wasm — and we own the math library.  Take advantage.

Concretely: the mandelbrot shader's inner loop becomes
```zig
z = z * z + c;   // Complex arithmetic, one line, looks like the math
```
instead of the current
```zig
z = zm.vec2(x2 - y2 + c[0], 2.0 * z[0] * z[1] + c[1]);
```

And the cube_split inline matrix functions delete because the same
`math.perspective` / `math.lookAt` / `math.rotateY` work on both
sides.

---

## Why this is hard (and why the plan is long)

### The duality that's been hiding in plain sight

I spent an embarrassing hour figuring out whether math.zig and
shadermath disagree on matrix convention.  They don't.  They're
**duals at the byte level** — the same 64 bytes encoding a 4×4 f32
matrix represent the same linear map in both conventions:

- math.zig writes `m[3] = (x, y, z, 1)` as "row 3" of a translation
  matrix, and computes `v * m = vx*m[0] + vy*m[1] + vz*m[2] + vw*m[3]`.
- shadermath calls those same bytes `m[3] = (x, y, z, 1)` "column 3"
  of a translation matrix, and computes `m * v = m[0]*vx + m[1]*vy
  + m[2]*vz + m[3]*vw`.

Identical scalars come out either way (commutative scalar mul + same
indexed reads).  The duality only breaks when you compose:
**`math.mul(A, B)` produces bytes that the shader interprets as
`B_col * A_col`** — i.e. the operand order swaps.

This is WHY render.zig writes `mul(view, proj)` (not `mul(proj, view)`)
when building view_proj.  The engine has been silently doing this
swap for as long as the typed-shader pipeline existed.  It works.
It's also confusing forever, and a real correctness landmine for
new contributors.

**The plan resolves this by picking one convention everywhere.**
We switch math.zig and shadermath to **column-major + `M*v` + `M = P*V*M_model`
order** — the GLSL standard.  The byte storage is unchanged (zero
runtime cost; the matrices were always compatible).  What changes
is:

1. `mul(A, B)` is renamed `mulMat(A, B)` and now means `A * B`
   (compose A AFTER B), so `mulMat(proj, mulMat(view, model)) * v`
   reads like the math.
2. `mul(v, M)` — the row-vector path — becomes deprecated.  All
   call sites flip to `mulMat(M, v)` (or `mulMatVec`).
3. `translation`, `rotateY`, `perspectiveFovLh` etc. are unchanged
   in storage but commented as "column-major: m[i] = column i".

This is a one-time grep-and-replace across the ~73 `zm.mul` call
sites.  Tractable.  After it's done, every Zig file in the codebase
— host or shader — reads matrix math the same way.

### The "what runs on SPIR-V" question

Of math.zig's 119 `pub fn`s, I expect ~80 to be pure (work on
SPIR-V verbatim once asserts are gated), ~25 to need mechanical
edits (`std.math.sin` → `@sin`), and ~14 to be genuinely host-only
(FFT, allocator-based decompose, std.fmt-printing helpers,
test-only `expectVecApproxEqAbs`).

The host-only set goes into a sibling module `src/math_host.zig`
that depends on math.zig.  The 41 importers that do
`const zm = @import("math.zig")` keep working unchanged — they get
both modules' surface through a re-export.  Shader code does
`const m = @import("math")` (build-wired) and only sees the
GPU-safe subset.

### The Camera3D-in-a-UBO trap

`Camera3D` today is `struct { position: Vec, target: Vec, up: Vec,
fovy: f32, projection: i32 }` — NOT `extern struct`.  Tight Zig
layout.  If we want to put it in a UBO directly so a shader can do
`const cam = io.u.camera; const mvp = cam.viewProj(aspect);`, the
struct has to be `extern struct` + std140-padded.

This is a real constraint.  The plan handles it by adding a
`Camera3DGpu` sibling type — `extern struct` with explicit padding,
constructible via `.toGpu()` from a regular Camera3D.  Doesn't
break existing host code; opens the door to shaders that operate on
camera data directly.

### Complex numbers (the headline feature)

Add `Complex` to math.zig as a type with operator overloading via
`@Vector(2, f32)` storage:

```zig
pub const Complex = @Vector(2, f32);

pub fn cmul(a: Complex, b: Complex) Complex {
    return .{ a[0]*b[0] - a[1]*b[1], a[0]*b[1] + a[1]*b[0] };
}
pub fn cadd(a: Complex, b: Complex) Complex { return a + b; }
pub fn cnorm2(z: Complex) f32 { return z[0]*z[0] + z[1]*z[1]; }
pub fn cabs(z: Complex) f32 { return @sqrt(cnorm2(z)); }
pub fn cexp(z: Complex) Complex { ... }  // exp(a+bi) = e^a * (cos b + i sin b)
pub fn clog(z: Complex) Complex { ... }
pub fn cpow(z: Complex, n: f32) Complex { ... }
```

Operator overloading via `@Vector(2, f32)` is partial — `+`/`-`
work natively; `*` does componentwise (NOT complex mul) so we have
to use `cmul`.  Could we add a real `Complex = struct { re, im: f32 }`
with `pub fn mul = ...` and host-only `pub const c = cmul`?  No —
struct types don't get the SIMD ops.  Best of both: pick
`@Vector(2, f32)` storage + `cmul` named function.  The mandelbrot
body becomes:

```zig
z = cmul(z, z) + c;
```

Three tokens.  Reads like math.  Compiles to the same SPIR-V as the
current verbose version because spirv-opt folds it.

Beyond mandelbrot, complex helpers unlock conformal-map shaders,
domain-coloring visualizations of analytic functions, FFT-on-GPU,
and "stereographic projection of the Riemann sphere" eye-candy demos.
Once `Complex` is a type with arithmetic, the rest writes itself.

### What this unlocks beyond the obvious

1. **Camera3D-driven shaders**: Push the camera struct to the UBO,
   shader does its own MVP / ray reconstruction.  No more "host
   bakes mvp, shader receives baked".
2. **SDF DSL**: `math.sdf.box`, `math.sdf.sphere`, `math.sdf.opUnion`,
   `math.sdf.opSmoothUnion` — composable via `comptime` so a shader
   author writes `const scene = sdf.opUnion(sdf.sphere(0.5),
   sdf.box(vec3(0.3, 0.3, 0.3)));` and the codegen folds it.
3. **Single ray-tracer source**: `examples/raytracer.zig` today is
   CPU-only.  Once `math.intersectRayTriangle` works on SPIR-V, the
   same ray-march body runs as a fragment shader (per-pixel) and a
   CPU loop (for debugging).
4. **Hot-swap CPU↔GPU for any algorithm**: any pure function in
   math.zig becomes A/B-comparable.  Catch numerical divergences
   (FMA, sin precision) by visual diff.

---

## The plan — ten stages, ~3 weeks of work

The phases are designed so each one is independently shippable.
We can stop at any phase and still have improved the codebase.
Phase 10 is the dream end-state.

### Stage -1: Vector2i → @Vector(2, i32) (1-2 hours)

Warm-up cleanup, independent of the matrix migration.  Removes the
last named-struct 2-vector in the codebase, making `Vec2` (f32) and
`Vector2i` (i32) sibling SIMD vectors with identical shapes.

**Why first**:
- Reversible, independent of any other phase, no semantic landmines.
- Gets the SIMD-vector idiom internalized before harder migrations.
- "Feels good" cleanup; demonstrates the migration cadence we'll
  use throughout.
- Today zimr has `Vec2 = @Vector(2, f32)` in both math.zig and
  shadermath but `Vector2i = struct { x, y: i32 }` — internally
  inconsistent.  Fix.

**Surface**: 12 files, 116 call sites.  `pub const Vector2i = struct
{ x, y, plus 6 methods }` (48 lines) → `pub const Vector2i =
@Vector(2, i32);` (1 line).

**Mechanical migrations**:
- `.x` / `.y` → `[0]` / `[1]`
- `.add(b)` → `+ b`
- `.sub(b)` → `- b`
- `.scale(k)` → `* @as(Vector2i, @splat(k))` (slightly verbose; the
  one ergonomic regression — splat must be explicit because `vec *
  scalar` doesn't compile for SIMD vectors)
- `.min(b)` → `@min(a, b)` (Zig builtin is vector-aware)
- `.max(b)` → `@max(a, b)`
- `.equals(b)` → `@reduce(.And, a == b)` or `std.meta.eql(a, b)`
- `Vector2i.init(a, b)` → `.{a, b}` (struct literal coerces)
- `Vector2i.zero()` → `@splat(0)`
- `Vector2i.one()` → `@splat(1)`
- `Vector2i.splat(v)` → `@splat(v)`

**Acceptance**:
- All 174 files build, 0 lint.
- 1880+/1880+ tests pass.
- Six standalones build at unchanged sizes (mandelbrot, mandelbrot_
  split, shader, shader_chroma_split, cube_split, damaged_helmet).
- Vector2i is `@Vector(2, i32)` in src/types.zig.

### Stage 0: Audit (1 day)

Goal: catalog every `pub fn` in math.zig.  Tag each as one of:
- **G** (gpu-safe today): no `std.debug`, no allocators, no `std.fmt`,
  no error returns, only `@Vector(N, f32)` / `f32` / arrays.  Ready.
- **GM** (gpu-safe with mechanical edit): touches `std.math.sin` /
  `std.math.tan` / `std.debug.assert` — fixable by routing through
  a `mathx_intrinsic` veneer.
- **H** (host-only): allocator-bearing (FFT unity table builder),
  test-only helpers, fmt printers, error sets.  Move to math_host.zig.

Output: a checklist `src/notes/math_audit.csv` with one row per
function.  Drives Stages 3, 4, 5.

**Acceptance**: 119 rows, each tagged G/GM/H, total = 119.

### Stage 1: Veneer module `math_intrinsic.zig` (0.5 day)

A new ~80-LoC module that exposes target-conditional intrinsics:

```zig
const builtin = @import("builtin");
const is_gpu = builtin.target.cpu.arch.isSpirV();

pub inline fn sin(x: f32) f32 {
    return if (comptime is_gpu) @sin(x) else std.math.sin(x);
}
// same for: cos, tan, asin, acos, atan, atan2, sqrt, exp, exp2, log,
//           log2, pow, floor, ceil, round, trunc, abs, fract

pub inline fn assert(cond: bool) void {
    if (comptime is_gpu) return; // no-op on SPIR-V
    std.debug.assert(cond);
}
```

Imported by math.zig itself.  All `std.math.sin(x)` calls in math.zig
become `@import("math_intrinsic.zig").sin(x)` (or via a local alias
`const mi = @import("math_intrinsic.zig"); mi.sin(x)`).

**Why a separate file**: keeps math.zig free of `if (is_gpu)`
branches.  The veneer is the only place that knows about the target.
Makes the host-only set easier to spot — anything in math.zig that
can't be routed through math_intrinsic stays host-only.

**Acceptance**: math_intrinsic.zig builds for both spirv32-vulkan
and wasm32; unit tests on host side verify it returns the same
values as `std.math` within float epsilon.

### Stage 2: Matrix convention switch (1.5 days)

The big mechanical migration.  Pick **column-major + `M*v`** as the
zimr-wide convention.

**The change in math.zig**:
- Rename `mul` (the polymorphic one) to `mulMat` (for Mat*Mat),
  `mulMatVec` (for Mat*Vec), `mulMatScalar` (for Mat*f32).
- The new `mulMat(A, B)` computes `A*B` in column-major terms.
  Implementation-wise: this is `B`-then-`A` in the old row-major
  view, i.e. **swap the operand order in the OLD impl**.
  Specifically:

  ```zig
  // OLD (row-major v*M, mul(A, B) means A then B):
  fn mulMat(m0: Mat, m1: Mat) Mat {
      var result: Mat = undefined;
      inline for (0..4) |i| {
          const v = m0[i];
          result[i] = splat(v[0])*m1[0] + splat(v[1])*m1[1] +
                      splat(v[2])*m1[2] + splat(v[3])*m1[3];
      }
      return result;
  }

  // NEW (column-major M*v, mulMat(A, B) means A then B in math order):
  pub fn mulMat(a: Mat, b: Mat) Mat {
      var result: Mat = undefined;
      inline for (0..4) |col| {
          // result column = A * (B's column)
          const bc = b[col];
          result[col] = splat(bc[0])*a[0] + splat(bc[1])*a[1] +
                        splat(bc[2])*a[2] + splat(bc[3])*a[3];
      }
      return result;
  }
  ```

  This is literally swapping the meaning of operand-order.  Same
  arithmetic count.  Same bytes out for the same bytes in (after
  the call-site swap).

- `mulMatVec(m, v)` IS shadermath's `mulMatVec` literally.  Move
  the impl in; rename the legacy `matMulVec` / `vecMulMat` to
  point at it.
- `mulMatPoint(m, p: Vec3)` is shadermath's `mulMatPoint`.

**The change at every call site**: 73 occurrences of `zm.mul`.  Each
falls into:
- `zm.mul(M, M)` → `zm.mulMat(P, V)` where the operand order
  **swaps** (because the convention changed from "left applies
  first" to "right applies first").  E.g.
  `mul(view, proj)` → `mulMat(proj, view)`.
- `zm.mul(v, M)` → `zm.mulMatVec(M, v)` (different function;
  operand order swaps).
- `zm.mul(M, v)` (rare; possibly only test code) → `zm.mulMatVec(M, v)`.

We do this as a single grep-and-replace pass, then walk every
modified site and verify the operand order swap.  ~73 sites, maybe
half are scalar*Mat (no swap needed; renamed to `mulMatScalar`).

**One subtle migration trap**: `translation`, `rotationY`,
`perspectiveFovLh` etc. produce bytes that, under the OLD convention,
were "matrices to right-multiply v against."  Under the NEW convention,
those SAME BYTES are matrices to left-multiply against v.  Because
the bytes are unchanged, the matrix-builder FUNCTIONS don't need to
change their bodies.  But their docstrings do: "column-major;
columns are [right, up, -forward, eye] for lookAtRh."

**Acceptance**:
- All 73 call sites migrated.
- Engine builds, all standalones render identically (mandelbrot,
  cube_split, damaged_helmet — visual diff).
- All 134 math.zig tests pass after the rename.
- `zm.mul` becomes a deprecated wrapper `pub const mul = mulMat;`
  for one stage to ease external user transition; remove in Stage 9.

### Stage 3: Port math.zig to compile on SPIR-V (the G + GM functions) (3 days)

This is where math.zig grows a `comptime is_gpu` veneer over its
host-isms.

- **Tests**: gate with `if (comptime !is_gpu)`.  Tests don't get
  compiled into shader binaries anyway (no `--test` flag on shader
  compile), but the test BLOCK still parses — and `std.testing`
  imports might break.  Wrap with `if (!is_gpu)` at the call level
  if needed, or just expect test blocks to compile-and-discard on
  SPIR-V.  (Zig's SPIR-V backend skips test blocks; verify.)
- **Asserts**: route through `math_intrinsic.assert` (no-op on GPU).
- **std.math.X**: route through `math_intrinsic.X`.
- **`std.fmt.comptimePrint`**: scan; replace with comptime string
  concat if used in `@compileError`.
- **Allocator-bearing functions** (FFT init table, etc.):
  add `comptime if (is_gpu) @compileError("X is host-only; use math_host.X");`
  at the top of the function body.  Don't remove — they're called
  from host code today.

**At end of stage 3**: math.zig compiles for `spirv32-vulkan` target.
We verify by adding a `tests/math_spirv_compile.zig` test fixture
that just `_ = @import("math.zig")` from a shader-target compile.
If math.zig has any expression that can't lower to SPIR-V, the test
fails at compile time.

**Acceptance**: `zig build-obj -target spirv32-vulkan -Mroot=tests/math_spirv_smoke.zig`
returns 0 exit code.  (Smoke fixture is `pub fn shaderMain(io: Io)
Out { _ = math.sin(io.x); return ...; }`.)

### Stage 4: math_host.zig sibling (1 day)

Extract the H-tagged functions from math.zig into `src/math_host.zig`.
These are:

- FFT unity table builders (allocator-bearing)
- Matrix decompose (returns errors for ill-conditioned input)
- std.fmt-bearing pretty printers
- Test helpers `expectVecApproxEqAbs`, `expectVecEqual`

`math.zig` keeps `pub const host = @import("math_host.zig");`.
Existing call sites `zm.expectVecApproxEqAbs` → `zm.host.expectVecApproxEqAbs`.

Why a re-export instead of duplicate top-level: keeps the 41 importers
unchanged.  They just see the host-only stuff under a `.host`
namespace now.  Easier to grep for "host-only math" at a glance.

**Acceptance**: math.zig has zero `std.debug.assert`, zero
`std.fmt`, zero allocator types in its own surface.  All such things
are reachable only through `zm.host.X`.

### Stage 5: Retire shadermath.zig (1 day)

Goal: every shader source imports `math` instead of `shadermath`.

- The build wires `--dep math=src/math.zig` for SPIR-V compiles
  (alongside the existing `--dep shadermath=src/shadermath.zig`,
  which we keep as a transition alias).
- Add `pub const shadermath = @import("math.zig");` somewhere
  reachable, so shaders that haven't migrated keep importing
  `shadermath` and silently get math.zig.

OR: We add a transitional `src/shadermath.zig` that re-exports
math.zig's surface 1:1:
```zig
pub usingnamespace @import("math.zig");
```
For the rare names that don't transfer (`shadermath.location`,
`shadermath.binding`, `shadermath.zsample2d`), keep those as
top-level functions in math.zig itself — they're shader-decoration
helpers, but they're trivially `noinline fn` of pure arithmetic.

- Migrate every `_fs.zig`, `_vs.zig`, every `_iface.zig`,
  every consumer of shadermath in tools/gen_shader_externs.zig.
  Each gets `const m = @import("math");` instead of
  `const zm = @import("shadermath");`.
- shadermath.zig becomes a 5-line shim: `pub usingnamespace
  @import("math.zig");` plus the decoration helpers.  Eventually
  deleted in Stage 9.

**Acceptance**:
- Every shader file uses `@import("math")`.
- The shim shadermath.zig is still importable for external users.
- All existing examples render bit-identically (or within FP
  epsilon — GLSL output may differ in formatting but should produce
  the same pixels).

### Stage 6: Complex numbers (1 day)

Add to math.zig:

```zig
pub const Complex = @Vector(2, f32);
pub const c_zero: Complex = .{ 0, 0 };
pub const c_one: Complex = .{ 1, 0 };
pub const c_i: Complex = .{ 0, 1 };

pub fn complex(re: f32, im: f32) Complex {
    return .{ re, im };
}

pub fn cmul(a: Complex, b: Complex) Complex {
    return .{ a[0]*b[0] - a[1]*b[1], a[0]*b[1] + a[1]*b[0] };
}

pub fn cdiv(a: Complex, b: Complex) Complex {
    const denom: f32 = b[0]*b[0] + b[1]*b[1];
    return .{ (a[0]*b[0] + a[1]*b[1]) / denom,
              (a[1]*b[0] - a[0]*b[1]) / denom };
}

pub fn cconj(z: Complex) Complex { return .{ z[0], -z[1] }; }
pub fn cnorm2(z: Complex) f32 { return z[0]*z[0] + z[1]*z[1]; }
pub fn cabs(z: Complex) f32 { return @sqrt(cnorm2(z)); }
pub fn carg(z: Complex) f32 { return mi.atan2(z[1], z[0]); }

pub fn cexp(z: Complex) Complex {
    const ea: f32 = mi.exp(z[0]);
    return .{ ea * mi.cos(z[1]), ea * mi.sin(z[1]) };
}
pub fn clog(z: Complex) Complex {
    return .{ mi.log(cabs(z)), carg(z) };
}
pub fn cpow(z: Complex, n: f32) Complex {
    // z^n = exp(n * log(z))
    return cexp(complex(n * clog(z)[0], n * clog(z)[1]));
}

// Iteration helpers (mandelbrot/julia)
pub fn cmandelbrot_step(z: Complex, c: Complex) Complex {
    return cmul(z, z) + c;
}
pub fn cjulia_step(z: Complex, c: Complex) Complex {
    return cmul(z, z) + c;  // same as mandelbrot; c is the parameter
}
```

Then migrate mandelbrot_fs.zig to use it.  The new body:

```zig
var z: m.Complex = .{ 0, 0 };
var i: u32 = 0;
while (i < 1024) : (i +%= 1) {
    if (@as(f32, @floatFromInt(i)) >= io_in.u.max_iter) break;
    if (m.cnorm2(z) > 256.0) { escaped = 1; break; }
    z = m.cmandelbrot_step(z, c);
    n += 1.0;
}
```

Visual A/B: produces bit-identical GLSL output to the current
hand-rolled version (spirv-opt folds the function call).  Same
pixels.  Source halved.

**Acceptance**:
- Complex tests pass on host.
- mandelbrot.html bytes within ±0.5 KB of pre-change baseline.
- Visual A/B: zoom to (-0.74364, 0.13182), iterations 256, pixels
  agree within 1 LSB per channel.

### Stage 7: First crazy demo — Julia-set explorer (1 day)

A new `examples/julia_split.zig`: same complex-arithmetic shader,
but `c` is a UBO parameter the user manipulates with the mouse.
CPU half via rlsw_shader; GPU half via WebGL.  Drag to set the
Julia parameter; watch the fractal morph; cursor X is the
windowshade divider.

This is a low-effort feel-good demo that showcases the new
`Complex` arithmetic + the entire software-shader pipeline + the
unified math story.

**Acceptance**: julia_split.html standalone, <300 KB.

### Stage 8: Camera3D-in-a-UBO (2 days)

Add `Camera3DGpu` to math.zig:

```zig
pub const Camera3DGpu = extern struct {
    position: Vec,  // w = 0
    target: Vec,    // w = 0
    up: Vec,        // w = 0
    fovy: f32,
    aspect: f32,
    near_z: f32,
    far_z: f32,
    // total = 48 bytes positions + 16 bytes scalars = 64 = std140-OK

    pub fn viewProj(self: Camera3DGpu) Mat {
        const view = lookAtRh(self.position, self.target, self.up);
        const proj = perspectiveFovRh(degToRad(self.fovy),
                                       self.aspect, self.near_z,
                                       self.far_z);
        return mulMat(proj, view);
    }
};

pub fn cameraGpuFrom(cam: Camera3D, aspect: f32) Camera3DGpu {
    return .{
        .position = cam.position,
        .target = cam.target,
        .up = cam.up,
        .fovy = cam.fovy,
        .aspect = aspect,
        .near_z = 0.1,
        .far_z = 1000.0,
    };
}
```

The host updates the camera as normal; pushes the GPU version each
frame; the shader does its own viewProj computation.  Shader code:

```zig
const m = @import("math");
pub fn shaderMain(io: Io) Out {
    var out: Out = undefined;
    const mvp = io.u.camera.viewProj();  // <-- shader does the math
    out.position = m.mulMatPoint(mvp, io.vertex_position);
    return out;
}
```

This is genuinely new capability — shaders can do view-dependent
math (frustum tests, ray reconstruction, view-space normals) using
the EXACT same Camera3D the scene system uses.

**Acceptance**:
- `examples/camera_in_shader.zig` — a spinning textured cube where
  the SHADER builds the MVP from the camera, not the host.  No
  performance loss (one extra mat-mat-mul per VS invocation, ~0.5 µs).
- Reuses cube_split's geometry + windowshade pattern.

### Stage 9: SDF DSL (2 days, optional)

```zig
// math/sdf.zig
pub fn box(p: Vec3, b: Vec3) f32 { ... }
pub fn sphere(p: Vec3, r: f32) f32 { ... }
pub fn opUnion(a: f32, b: f32) f32 { return @min(a, b); }
pub fn opSmoothUnion(a: f32, b: f32, k: f32) f32 { ... }
pub fn opSubtract(a: f32, b: f32) f32 { return @max(-a, b); }
pub fn opIntersect(a: f32, b: f32) f32 { return @max(a, b); }
```

Composable in shader source:

```zig
fn scene(p: m.Vec3) f32 {
    const s = m.sdf.sphere(p - m.vec3(0, 0.5, 0), 0.5);
    const b = m.sdf.box(p - m.vec3(0, -0.3, 0), m.vec3(2, 0.1, 2));
    return m.sdf.opSmoothUnion(s, b, 0.2);
}

pub fn shaderMain(io: Io) Out {
    // ray-march scene(), return color
}
```

`examples/sdf_split.zig` — first SDF ray-march demo with the
windowshade divider.  Probably renders at 30fps GPU, 0.5fps CPU
— accept the asymmetry as part of the demo's "see the work" theme.

**Acceptance**: a recognizable shape on both sides; pixels agree
within tolerance.

### Stage 10: Documentation + delete (1 day)

- Write `src/notes/math.md` — the new public guide.  "math.zig is
  zimr's universal math library.  It compiles for host and shader
  targets.  Conventions: column-major; M*v; std140-padded structs
  for UBO use; ..."
- Delete the shim `src/shadermath.zig`.
- Delete the deprecated `mul` wrapper.
- Delete `tools/gen_shader_externs.zig`'s shadermath dep —
  point at math directly.

**Acceptance**: zero references to "shadermath" anywhere except
in git history.  `src/shadermath.zig` file does not exist.

---

## Risks and mitigations

### Risk: SPIR-V backend doesn't support some operation in math.zig

Mitigation: Stage 0 audit catches most of these.  For surprises in
Stage 3, gate behind `if (comptime !is_gpu)` + `@compileError`.
Move that specific function to math_host.

### Risk: float precision differs between targets (cube_split already shows this — bilinear vs nearest)

Mitigation: this is expected and documented.  Tests use
`approxEqAbs` with epsilon = 1e-5 for "passes on both sides".
Visual diffs use 99.5% pixel-agreement threshold.

### Risk: external users of zimr break on the `mul` → `mulMat` rename

Mitigation: keep `pub const mul = mulMat;` as a deprecated alias
through Stage 9.  Emit a `@compileLog` in debug builds.  Document
the rename in MIGRATION.md.

### Risk: 73 call sites of `mul` is more than I think when I look at the swap semantics

Mitigation: Stage 2 is timeboxed at 1.5 days.  If swapping operand
order at one site requires fixing 3 other sites, we just spend the
time — but if it explodes to a week, we pause and reconsider.  The
fallback is to leave `mul` unchanged and ONLY add the new
`mulMat`/`mulMatVec` — call sites that want clarity migrate
voluntarily; legacy code stays the same.  That degrades the
"unified" story (two names for one operation) but keeps the work
bounded.

### Risk: Camera3DGpu's std140 layout is subtly wrong

Mitigation: write a Zig test that reflects on Camera3DGpu's field
offsets and compares them to spirv-cross's --reflect output for an
equivalent UBO.  Lock the layout at the bytes.

### Risk: Complex numbers via `@Vector(2, f32)` collide nominally with `Vec2`

This is real.  `Complex == Vec2` at the type level (they're both
`@Vector(2, f32)`).  Functions like `cmul(a: Complex, b: Complex)`
would also accept Vec2 args.  Mitigation: name discipline.
`cmul` is for complex; `mulVec2` (or just `*` for componentwise) is
for vector componentwise multiply.  Document in the math.md header.

Alternative: make Complex a `struct { re: f32, im: f32 }` and lose
the SIMD-free `+`.  Costs nothing on GPU (spirv-opt folds), some
codegen ugliness on CPU.  **Recommendation**: keep `@Vector(2, f32)`
storage but introduce Complex as a comptime-distinguished alias if
Zig supports `pub const Complex = enum_literal type alias`.  If
not, document.

---

## Iface co-location experiment (2026-05-26) — viable

Brainstormed, prototyped, and validated: co-locating the iface
schema (Inputs / Outputs / Ubo) inside the shader source file
instead of a sibling `_iface.zig` works under Idea #2 (stub io
module for the codegen bootstrap).

**The constraint that makes it hard**: the codegen bootstrap exe
runs BEFORE the SPIR-V compile.  Today it imports the iface as a
standalone Zig module and reflects on its types.  If iface decls
live inside the shader source, bootstrap must import the SHADER
file, which has `const io = @import("foo_fs_io")` at module
scope — and io.zig doesn't exist yet (it's what bootstrap is
about to GENERATE).

**The solution**: hand bootstrap a host-target STUB of io that
satisfies the import without doing anything real.  Same fn names
and field names as the actual generated io.zig (`IoT(T)`, `Out`,
`installSpirvEntry`) but trivial bodies bootstrap never runs.
Bootstrap reflects only on the iface decls at the top of the
shader file (which don't depend on io); the body's `shaderMain`
signature uses `io.IoT(Ubo)` and `io.Out` which the stub provides
matching surface for, so the file typechecks end-to-end.

**Implementation**:
- `tools/iface_io_stub/io_stub.zig` (~20 lines) — the stub.
- `ShaderOpts.iface_inline: bool` (default false) — opt-in flag.
- When `iface_inline = true`, iface_mod gets the stub as an
  additional `addImport(io_module_name, stub_mod)`.
- `build.zig` heuristic: shader basename ending in `_inline_fs`
  AND no sibling `_iface.zig` triggers iface_inline mode.
- Prototype shader: `examples/mandel_inline_fs.zig` — combined
  iface + body, ~110 lines including hsv2rgb.
- Driver: `examples/mandel_inline.zig` — imports the shader file
  AS the iface (`const iface = @import("mandel_inline_fs.zig")`),
  reaches Ubo via the `pub const iface = @This()` re-export.

**Result**: `mandel_inline.html` builds at 156/269 KB — same
wasm/bundle size as `mandelbrot.html` at 157/270 KB.  All
existing separate-iface shaders still build unchanged.  Tests
pass.  Visual output matches mandelbrot.html (same iteration,
same coloring).

**Constraint on the stub**: it hardcodes the canonical
(frag_tex_coord, frag_color) Inputs surface that every current
fragment shader uses.  Vertex shaders, PBR-style FS with extra
varyings (normal, tangent, uv1, uv2), or shaders with samplers
in the Inputs would need a richer stub — or a per-shader
generated stub, which defeats the simplicity.

**Status**: experimental.  The pattern is OPT-IN per shader via
the `_inline_fs` basename suffix.  Separate-iface stays the
default for shaders that don't fit the constraint (vertex
shaders, complex FS).  Mandelbrot + julia + mandel_julia still
use separate ifaces; only `mandel_inline` demonstrates the
combined pattern.

**Honest assessment**: the ergonomic win is real but small.
The iface files are typically <30 lines of plain Zig structs —
not enough boilerplate to justify a build-system complication
across every shader.  Worth keeping the option for shaders where
the iface IS just 3 simple structs and the visual/cognitive
unification feels right.  Not worth migrating every existing
shader.

---

## Inline-iface as default + explicit build.zig table (2026-05-27)

User feedback after the experiment: the iface-inline pattern is
strictly better for the common case (one shader, one iface),
and the `_inline_fs` filename suffix is a build-system detail
leaking into the user namespace.  Two related changes landed:

**Change 1: Inline iface is now the DEFAULT, external is opt-in.**
The pre-2026-05-27 implementation had external iface as default
(sibling `<name>_iface.zig` file) with inline as a special case
triggered by the `_inline_fs` filename suffix.  Now reversed:
inline is what you get by default (declare Inputs / Outputs /
Ubo at the top of the shader source), and external iface is
explicit (declared in the build.zig shader table).

External iface still has TWO legitimate use cases that justify
keeping it as an option:
  - Shared between VS + FS varyings (e.g. `cube_split` —
    `cube_split_vs_iface.zig` declares the VS Outputs that must
    match the FS Inputs).
  - Shared between multiple examples (e.g.
    `shader_chroma_fs_iface.zig` — imported by both
    `examples/shader.zig` and `examples/shader_chroma_split.zig`).

For everything else (mandelbrot, julia, mandel_julia,
shader_uniforms) inline is now the convention.

**Change 2: build.zig has an explicit `shaders` table.**
The pre-refactor `build.zig` did sibling-file auto-discovery:
look for `examples/<name>_iface.zig` next to
`examples/<name>_fs.zig`, branch between three modes (typed-
external / typed-inline / legacy-hand-written) based on filename
existence and suffix heuristics.

That implicit graph was fragile.  Misspell the iface filename →
silent legacy mode.  Forget the `_inline_fs` suffix → silent
legacy mode.  The compiler couldn't help.

New `shaders` table at the top of `build.zig`:
```zig
const ShaderSpec = struct {
    source: []const u8,        // examples/<source>.zig
    iface: ?[]const u8 = null, // null = inline (default)
};
const shaders = [_]ShaderSpec{
    .{ .source = "mandelbrot_fs" },              // inline
    .{ .source = "julia_fs" },                   // inline
    .{ .source = "mandel_julia_fs" },            // inline
    .{ .source = "shader_uniforms_fs" },         // inline
    .{ .source = "cube_split_vs", .iface = "cube_split_vs_iface" },
    .{ .source = "cube_split_fs", .iface = "cube_split_fs_iface" },
    .{ .source = "shader_chroma_fs", .iface = "shader_chroma_fs_iface" },
};
```

Diff-friendly: every shader's mode is visible in one block.
Lookup-not-dir-access at build time.  Missing rows trigger a
`@panic` with a precise error message including the suggested
table entry — surfaces the missing row at the place that needs
editing instead of dropping silently to legacy mode.

**Migrations bundled with this change**:

1. `mandelbrot_fs.zig` migrated from external-iface to inline.
   `mandelbrot_fs_iface.zig` deleted.  CPU drivers (`mandelbrot.zig`,
   `mandelbrot_split.zig`) updated to import the shader file
   directly as the iface.

2. `shader_uniforms_fs.zig` migrated from legacy hand-written
   externs (the last holdout of the pre-Phase-2 pattern) to typed
   inline iface.  `shader_uniforms.zig` (CPU side) modernised
   from the three-step `loadShaderFromMemory` + `Ub.create` +
   `attach` dance to the unified `loadShaderWithUbo` call.  This
   retires the legacy hand-written-externs code path entirely —
   every typed-iface shader in zimr now uses the same pipeline.

3. Renames:
   - `julia_inline_fs.zig` → `julia_fs.zig`
   - `mandel_julia_inline_fs.zig` → `mandel_julia_fs.zig`
   - `mandel_inline_fs.zig` + `mandel_inline.zig` deleted
     (redundant — `mandelbrot.zig` itself now uses inline iface).

**Audit at completion**:
- Shader files now follow the natural `<name>_fs.zig` /
  `<name>_vs.zig` convention with NO filename suffixes encoding
  build-system state.
- 4 shaders use inline iface (mandelbrot_fs, julia_fs,
  mandel_julia_fs, shader_uniforms_fs).
- 3 shaders use external iface (cube_split_vs, cube_split_fs,
  shader_chroma_fs) — each has a documented reason (shared VS+FS
  or shared between examples).
- All standalones build at unchanged sizes (mandelbrot 157/270 KB,
  julia 157/271, mandel_julia 164/280, shader_uniforms 154/267,
  cube_split 178/299, shader 88/179, shader_chroma_split 175/295,
  damaged_helmet 3996/5389).
- 1900/1900 tests pass.
- 0 lint.

**Three modes → two modes.** Legacy hand-written externs path is
gone.  The `iface_inline` opt on `ShaderOpts` remains because the
shader_pipeline (`src/shader_codegen.zig`) is the place that needs to
know whether to wire a stub io module to the bootstrap — that's
a real implementation detail.  But callers no longer have to
discover the mode through filename inspection; they read it from
a table.

---

## Stage 10 (2026-05-27) — shadermath deleted, math.md written ✅

The math-unification arc closes.  ~45 minutes including the doc.

**What landed**:

1. **`src/shadermath.zig` deleted** (447 lines).  Per locked
   decision D8 — no shim, no migration period.  At deletion
   time the file had zero importers in code; only docs
   referenced it.

2. **`src/shader_codegen.zig` purged of `shadermath_mod`** — the
   `ShaderPipeline` struct loses a field, `init()` loses an
   arg, the `iface_mod.addImport("shadermath", …)` line goes
   away.  Iface files now reach math types via `@import("zm")`
   exclusively (which they already did since Stage 5).

3. **`build.zig` purged of shadermath wiring** — the
   `shadermath_mod_for_zls` module declaration, the ZLS shadow-
   module loop's shadermath entry, the `exe_mod.addImport(
   "shadermath", …)` call, the io-module imports' shadermath
   entry, the `exe_mod_smoke` and `test_mod` shadermath imports,
   the cross-example share's shadermath entry.  All deleted.
   The `ShaderPipeline.init` call site loses one arg.

4. **`src/notes/math.md` written** — the public guide.  Covers
   the type table, operation index, conventions (column-major,
   std140 padding, (x,y,z,w) quaternions, the Complex `*` gotcha),
   limitations (vector trig on SPIR-V, `std.math` transcendentals,
   `bool` storage), shader-side + host-side ergonomics.  Links
   back to math_unification.md for history.  Single-file canonical
   reference.

**Stale comment cleanup**: `src/zimrmath.zig`, `build.zig` updated
to drop dangling references to "shadermath" in doc comments.
Notes still reference it (it's history).

**Audit**:
- 173 files (was 174; -1 for shadermath.zig).
- 0 lint.
- 1900/1900 tests pass.
- Every standalone unchanged: mandelbrot 157/270 KB, julia
  157/271, mandel_julia 164/280, shader_uniforms 154/267,
  cube_split 178/299, shader 88/179, shader_chroma_split 175/295,
  damaged_helmet 3996/5389.

**The arc**:
- Phase -1 (Vec2i SIMD)
- Stage 0 (audit)
- Stage 1 (math_intrinsic veneer, later consolidated)
- Stage 2 (matrix convention switch, polymorphic mul deleted)
- Stage 3 (math.zig → SPIR-V port; math_intrinsic inlined)
- Stage 5 (shadermath retirement: shaders migrated to zm)
- Phase 0.5 (Complex first-class)
- Mandelbrot + Julia + mandel_julia demos
- Iface-inline experiment + adoption as default
- build.zig explicit shader table
- **Stage 10: delete shadermath, write math.md**

**What didn't happen**:
- Stage 4 (math_host sibling) — skipped, Zig lazy compilation
  made it unnecessary.
- Stage 8 (Camera3D-in-a-UBO) — deferred until a real use case.
- Stage 9 (full SDF kit) — minimal kit landed inline in zm;
  expansion deferred.
- Post-plan Cornell box flagship — deferred.

The unified math module is the canonical math for zimr.
`src/notes/math.md` is the canonical guide.  Done.

---

## What I want input on (rubberducking section)

### Decisions locked

**D1 (locked 2026-05-26)**: Final names are `mulMat`, `mulMatVec`,
`mulMatScalar` — explicit, no polymorphism, no `mul` shorthand.
The transitional names ARE the final names; no rename pass at end.
Rationale: a typo like `mul(v, M)` vs `mul(M, v)` would silently
type-check under polymorphism and produce wrong results.  Explicit
signatures force the writer to commit at the call site.  The
explicit-name convention is the documentation we're paying for by
doing this migration.

**D2 (locked 2026-05-26)**: Phase -1 (Vector2i → `@Vector(2, i32)`)
runs first as a warm-up.  Then Complex numbers ship EARLY as Phase
0.5 — slotted in right after Phase -1 and the audit, BEFORE the
matrix migration.  Rationale: Complex is purely additive (~50
LoC), zero risk to existing code, and delivers the mandelbrot
one-liner — the headline payoff — on day 1.  De-risks the
migration: if the matrix work stalls, the visible value has
already shipped.  The cost of adding Complex helpers to both
math.zig AND shadermath during the transition (~10 LoC of
duplication) gets reabsorbed when shadermath is retired in Stage
5.  Complex stays `@Vector(2, f32)` (see Q3 below for type-shape
discussion).

**D3 (locked 2026-05-26)**: `pub const Complex = @Vector(2, f32);`
— SIMD alias for Vec2, no nominal wrapper.  `+`/`-` work natively
(the whole point: `z = cmul(z, z) + c` is the headline one-liner).
`*` is componentwise (NOT complex mul); use `cmul` for complex
multiplication.  Function naming is the discipline that replaces
nominal type safety.  Accepted cost: `cmul(some_vec2, some_vec2)`
will type-check and produce mathematically-correct-but-semantically-
wrong results.  Documented in math.md.

**D4 (locked 2026-05-26)**: Stage 8 adds `Camera3D.Gpu` as a
nested `extern struct` inside Camera3D (in `src/types.zig`).
Host code keeps using `Camera3D` unchanged (SIMD-friendly,
tightly packed).  Shader-bound UBOs use `Camera3D.Gpu`
(std140-padded, `[4]f32` arrays instead of `@Vector(4, f32)`
to avoid the documented wasm-OOB bug from putting SIMD vectors
inside extern struct).  Conversion: `cam.toGpu(aspect)`.

The nested-type pattern keeps both types co-located in one file
so a new field on Camera3D is obviously a candidate for
Camera3D.Gpu too — drift risk is mitigated by proximity, plus a
comptime size-check sentinel in tests.

**TODO (post-plan)**: investigate single-type unification — i.e.
make Camera3D itself the extern std140-padded shape and delete
Camera3D.Gpu.  Blockers: (1) the wasm-OOB regression from putting
`@Vector(4, f32)` inside extern struct documented in
`src/types.zig` — would need a fresh look at whether current Zig
0.16 still has this issue; (2) ripple effect through every
Camera3D consumer (scene system, gltf loader, beginMode3D,
drawCubeV, render passes).  Worth a dedicated investigation
session before committing — likely a 1-day spike to measure the
diff size and verify the historical bug is gone.  If both check
out, fold Camera3D.Gpu back into Camera3D as a follow-up phase.

**D5 (locked 2026-05-26)**: Stage 9 ships a minimal SDF kit only:
`sdf.sphere`, `sdf.box`, `sdf.plane`, `sdf.opUnion`,
`sdf.opSmoothUnion`, `sdf.opSubtract`, `sdf.opIntersect`.  ~50
LoC, one demo (`examples/sdf_split.zig`), 2 days as planned.

Rationale: the minimal kit is enough to prove the pattern
(SDFs compose via comptime function calls; codegen folds them
into one fragment program).  Bigger ambitions (domain-warping
ops, normal estimation, AO, SDF text rendering, font glyph SDFs)
deserve their own dedicated weeks AFTER seeing the minimal version
in action — we'll know what's painful and what's missing.  Logged
as post-plan follow-ups.

**TODO (post-plan, optional)**: SDF playground expansion — torus,
capsule, cylinder, roundedBox, opTwist/Bend/Repeat, normal
estimation via gradient finite-differences, AO approximation,
soft shadows.  ~300 LoC, 1-2 weeks.  Becomes a "shadertoy in
Zig" sub-library.

**TODO (post-plan, optional)**: SDF text rendering — font glyph
SDFs, distance-field font atlases, sharp scalable UI text.
Interleaves with font_cache work.  1-2 weeks.

**D6 (locked 2026-05-26)**: Stage 0 audit output is
`src/notes/math_audit.csv` — operational data in its own file,
greppable + sortable.  Columns: `fn_name, category (G/GM/H),
lines_of_code, notes`.  Updated incrementally as migrations
proceed (a function tagged GM transitions to G after Stage 3
when its `std.math` calls route through `math_intrinsic`).
The plan doc keeps a one-paragraph summary; the CSV does the
tracking.  Expected breakdown: ~80 G, ~25 GM, ~14 H, total 119.

**D7 (locked 2026-05-26)**: Hybrid downtime strategy.  Stage 2
(the matrix convention switch) accepts a ~24-48 hour broken
window — done in one big commit across all 73 call sites,
because the dangerous half-migrated states ("half row-major,
half column-major") are unverifiable.  Every OTHER stage stays
green-committable: Stages -1, 0.5, 6-9 are purely additive
(zero rendering risk); Stages 3-5 (SPIR-V port, math_host,
retire shadermath) are incrementally migratable per-function or
per-shader.

Operational note: Stage 2 should be done on a single
uninterrupted block of time (not spread across evenings).  The
sequence: write `mulMat`/`mulMatVec`/`mulMatScalar` → DELETE the
old `mul` → walk every compile error → fix operand order →
verify ALL standalones render correctly → commit.  Between
"delete mul" and "all standalones render", the engine is in
the broken window and visual A/B is unreliable.

**D8 (locked 2026-05-26)**: shadermath.zig is **deleted** in
Stage 10.  No shim survives.  Anyone importing `shadermath` at
that point hits a "module not found" error and migrates to
`@import("math")` — a one-grep fix.  Pre-1.0 is the right time
to break interfaces; the cognitive cost of leaving a
"secret backup name" in IDE autocomplete and grep results
forever outweighs the convenience of a 5-line shim.  The
deletion commit message + the new `src/notes/math.md` document
the migration explicitly.

**D9 (locked 2026-05-26)**: Quaternions stay `(x, y, z, w)` —
vector part first, scalar part in `w`.  Identity is `.{ 0, 0, 0,
1 }`.  Matches raylib, gltf 2.0, DirectX, GLM — the ecosystem
zimr's built on.  Stage 10 adds a documentation block at the
Quat declaration in math.zig explicitly calling out the
convention for newcomers translating from math papers (which
typically write `q = w + xi + yj + zk` with scalar first).  No
migration; no future TODO.  This is the convention zimr commits
to.

**D10 (locked 2026-05-26)**: Post-plan flagship demo is the
**ray-traced Cornell box** — a follow-up after Stage 10 ships.
Strongest demonstration of the unification thesis: same Zig
ray-triangle intersection code running on both pipelines, same
visible output (within FP precision), windowshade divider
revealing CPU vs GPU rendering of identical scene.

Incremental path:
1. **Cornell-spheres** (1 day): two spheres in a 3-sided box,
   primary rays only.  Tests `intersectRaySphere`, Camera3D.Gpu
   ray reconstruction, math.zig geometric primitives on SPIR-V.
2. **Cornell-cubes** (1 day): add the two classic cubes.  Tests
   `intersectRayTriangle` against AABB-formed meshes; tests
   triangle-mesh iteration in a shader.
3. **Cornell-pathtraced** (longer follow-up, optional): add
   bounce light, soft shadows via stratified sampling,
   progressive accumulation across frames.  CPU at 1fps with
   thousands of samples; GPU at interactive rates with fewer.

Rationale: iconic graphics demo, credibility marker, exercises
the parts of math.zig (geometric primitives) that mandelbrot
and SDF demos DON'T touch.  Validates the SPIR-V port is
broader than transcendentals.  Cathedral (A) was visually
stronger but concentrated value in the SDF DSL already shipped;
Riemann sphere (C) was cool but esoteric.  Cornell box sells to
the broadest audience.

## Implementation log

### Stage 3 (2026-05-26) — Port math.zig to compile on SPIR-V ✅ (partial)

Total time: ~2.5 hours including the math_intrinsic consolidation.

**What landed**:
1. **Routed `assert` and trig through internal helpers** — math.zig's
   `const assert = @import("utils.zig").assert;` changed to a local
   `pub inline fn assert(...)` that's no-op on SPIR-V (`utils.zig`'s
   assert pulls in `build_options` + panic infra that don't lower).
2. **Scalar trig polynomial fallbacks** (`atanScalar`, `atan2Scalar`,
   `asinScalar`) inlined into math.zig.  `atan2(scalar)` and
   `asin(scalar)` now route through them on both targets — bit-
   identical output between CPU and GPU.  Replaces the 6 internal
   `std.math.atan2` / `std.math.asin` call sites that used lookup
   tables incompatible with SPIR-V Logical addressing.
3. **`std.math` re-exports cleaned up** — `pow`, `tan`, `log2`,
   `exp2` stay as `std.math.X` (generic-T signature needed for host
   f64 callers); `degreesToRadians`, `radiansToDegrees`, `isFinite`,
   `inf`, `nan`, `floatEps`, `floatMax`, `signbit` re-export
   directly from std.math.  All are SPIR-V-safe because their
   bodies are pure arithmetic.
4. **`@exp2` builtin** replacing `std.math.exp2` in
   `lerpOverTime`/`lerpVOverTime` — generic-T builtin works on
   both targets and lowers to GLSL.std.450.Exp2 on SPIR-V.

**The consolidation (your suggestion)**: math_intrinsic.zig deleted
entirely.  Its body (~340 lines) inlined into math.zig as a small
top-level section.  Rationale: the veneer abstraction was useful
during Stage 1 but became navigational tax once math.zig was the
single consumer.  Side benefits beyond fewer files:
- No more cross-module dep graph for assert / scalar trig.
- No "no module named 'math_intrinsic' available within module X"
  errors that were chasing me through build.zig / shader_codegen.zig /
  exe_mod / exe_mod_smoke / ZLS module declarations.
- The shadowing risk with my local `mi` variable (matrix-inverse)
  is gone.
- Polynomial atans now live next to their callers.

Unwired from build.zig (math_intrinsic module decl, zimr_mod imports,
exe_mod imports, exe_mod_smoke imports, ZLS shader-module imports,
math_intrinsic_smoke_fs fixture).  Unwired from shader_codegen.zig
(--dep / -Mmath_intrinsic in shader pipeline).  Net: build.zig 1726
lines (was 1726 +decls).

**SPIR-V incompatibilities found** (each forced a small refactor):

1. **Module-scope `const Vec` declarations** lower to a private
   storage variable that requires an `OpLoad` through a non-logical
   pointer — SPIR-V Logical addressing rejects.  Converted
   `f32x4_sign_mask1`, `f32x4_mask2`, `f32x4_mask3` from `const`s
   to `inline fn`s returning vector literals.  The compiler emits
   `OpConstantComposite` and uses it inline — no load.  5 call
   sites updated to `mask_name()` form.

2. **Vector-level `@bitCast` from `Vec` to `@Vector(4, u32)`** —
   used by `andInt` / `orInt` / `xorInt` to do bitwise ops on
   float vectors.  Same Logical-pointer rejection.  Componentwise
   scalar bitcasts (lane-by-lane) DO work; vector-level doesn't.
   Rewrote `cross3` to use `@shuffle` to zero the w lane instead
   of `andInt(result, mask3)` — single `OpVectorShuffle` op,
   cleaner SPIR-V output.

**What still doesn't work on SPIR-V** (post-Stage-3 follow-up):
- Vector trig (`zm.sin/cos/atan/sincos` on `Vec`/`F32x8`/`F32x16`)
  — zmath's bodies use `andInt`/`orInt`/`xorInt` for sign-bit
  manipulation.  33 call sites in math.zig.  Rewriting the int-op
  family to use componentwise scalar bitcasts is the fix; deferred
  as post-Stage-3 work.  For now, shader code uses SCALAR forms
  via `atan2(f32, f32)` / `asin(f32)` (these route to the polynomial
  fallbacks that don't touch the int-op family).
- FFT family (`fft`, `ifft`, `fftInitUnityTable`) — already H-
  category in the Stage 0 audit; never intended for GPU.

**The Stage 3 smoke shader** (`tests/math_full_smoke_fs.zig`)
imports `math` directly and exercises: vector arithmetic, splat,
swizzle, cross3 + dot3 + normalize3, the column-major matrix API
(translation, mulMat, mulMatVec, mulMatPoint, identity), and
scalar trig (atan2, asin) via the polynomial fallbacks.  Compiles
cleanly through SPIR-V → spirv-opt → spirv-val → spirv-cross.
Wired into `zig build test` as a fixture.

**Audit**:
- 174 files (was 175 with math_intrinsic.zig), 0 lint.
- All 1884/1884 host tests pass.  Stage 3 smoke fixture passes.
- All six standalones at unchanged sizes (270/274/179/295/299/5389
  KB).  No host-visible behavior change.

**The unlock**: shader source files can now `@import("math")` and
use the same Vec / Mat / Quat algebra as the CPU side.  No need
to mentally maintain a "shadermath subset vs math.zig superset"
boundary — they're the same library now (for the GPU-portable
subset, which is most of math.zig).  Stage 5 retires shadermath
entirely in favor of math; the path is clear.

---



### Stage 5 (2026-05-26) — Retire shadermath ✅ (no shader file imports it anymore)

Total time: ~4 hours including a substantial detour through Zig 0.16
module-system landmines.

**What landed**:
1. **All 19 shader files migrated** from `@import("shadermath")` to
   `@import("zm")` (the new module name — see "the module name
   problem" below for why not "math").  Mechanical sed; one shader
   file (tests/fixture_fs.zig) also needed `zm.x(v)` / `zm.y(v)` /
   `zm.z(v)` / `zm.w(v)` accessor calls rewritten to `v[0]` /
   `v[1]` / `v[2]` / `v[3]` because adding component-accessor fns
   to math.zig would shadow zmath's 30+ local `const x: f32 = ...`
   bindings.
2. **29 CPU-side path imports** of `math.zig` migrated from
   `@import("math.zig")` to `@import("zm")` (module form) so the
   file isn't claimed by two modules at the same time (Zig 0.16
   rejects "file in two modules" with a hard error).
3. **3 SPIR-V decorators** (`location`, `binding`, `zsample2d`)
   moved from shadermath.zig into math.zig at the bottom, so
   shader code needs only one import for everything it uses.
4. **`vec3(x, y, z) Vec3` constructor** added to math.zig (zmath
   had `vec(x, y, z) Vec` which returns a 4-wide vector with
   w=0 — different shape from shadermath's `vec3`).  Both coexist.
5. **`pow` rewritten** from `pub const pow = std.math.pow` (3-arg
   generic-T) to `pub inline fn pow(base: f32, exponent: f32) f32`
   using `@exp(@log(base) * exponent)`.  std.math.pow has an f64
   internal path that SPIR-V rejects ("floating point width of 64
   bits is not supported for the current SPIR-V feature set");
   the GLSL-style 2-arg form is SPIR-V-portable AND matches what
   shadermath used to provide.  29 host call sites rewritten from
   `zm.pow(f32, x, y)` to `zm.pow(x, y)` + 13 locals annotated
   `: f32` (the typed-call provided inferred return type before).
6. **`tools/gen_shader_externs.zig`** updated: codegen now emits
   `const zm_mod = @import("zm");` instead of
   `@import("shadermath");`.  io.zig files transitively need `zm`
   as a `--dep`, wired in shader_codegen.zig's shader pipeline.
7. **Build wiring**: math module declared once in build.zig as
   `addModule("zimr_math", ...)` (the global registration name
   must NOT collide with std's internal "math" module — see
   below), exposed to consumers under the local import name
   "zm" via `addImport("zm", math_mod)`.  Wired into zimr_mod,
   zimr_mod_smoke, exe_mod, exe_mod_smoke, iface_mod, io modules,
   test_mod, and the shader compile (`--dep zm` + `-Mzm=src/math.zig`).
   shadermath module is no longer a `--dep` of any shader compile
   or io compile — completely retired from the live build graph,
   though shadermath.zig still exists on disk (Stage 10 deletes
   it per locked decision D8).

**Three Zig 0.16 module-system landmines hit during this stage**
(each cost real time; documenting so future stages don't repeat):

1. **`usingnamespace` is gone in Zig 0.16.**  The plan's
   transitional-shim approach (`pub usingnamespace @import("math.zig");`)
   doesn't compile.  Stage 5 went straight to full migration
   instead of a re-export shim.  Faster in the end.

2. **Module-name collision with std's internal `math` module.**
   Naming my `addModule("math", ...)` triggers
   `error: no module named 'math' available within module 'std'`
   in compiler_rt during sub-compilation.  std.zig:86 does
   `pub const math = @import("math.zig");` (PATH form, not module
   form — important!) but the compiler's sub-compilation pipeline
   somehow conflicts when a user-level module is also named "math".
   **Fix**: name the module globally as "zimr_math" but use the
   import alias "zm" at every call site.  No collision because
   "zimr_math" and "math" are distinct names.

3. **Target mismatch causes Zig 0.16 compiler segfault.**  When
   `math_mod_for_zls` was created with `.target = wasm_target`,
   any host-target compile (e.g. the native test binary) that
   transitively pulled in math through an `addImport("zm", math_mod)`
   produced `error: process terminated with signal SEGV` — no
   useful diagnostic, just a crash.  **Fix**: omit `.target` from
   the addModule call entirely.  The module inherits its target
   lazily through consumers, which works for both wasm and native
   compiles.

**The "file exists in modules X and Y" gauntlet**: Zig 0.16
rejects when the same source file is reachable through two
different *named* modules.  Stage 5 hit this 4 times:
- `cube_split_vs.zig` reached via both shader compile and CPU
  shim path → fixed by ensuring exe_mod has math as a named import
  so the CPU shim's `@import("zm")` resolves to the SAME module
  as the shader compile's.
- `math.zig` reached via `src/zimr.zig`'s `pub const math =
  @import("math.zig")` AND via the new math module → fixed by
  switching zimr.zig to `@import("zm")` (module form).
- Same issue, `src/tests/transform_order_test.zig` and
  `src/tests/scene_test.zig` had `@import("../math.zig")` (path
  form with `../`) that my first sed sweep missed → caught on
  second pass, fixed to `@import("zm")`.

**The Zig stdlib corruption mishap**: an early sed sweep was too
broad (`find src/ examples/ tests/ tools/ -name "*.zig" | xargs
sed -i ...`) and touched
`tools/zig-x86_64-linux-0.16.0/lib/std/std.zig:86`, changing
`@import("math.zig")` (path form, the correct one) to
`@import("math")` (module form).  This caused std to fail to
find its own math module in EVERY subsequent build with errors
that looked like Zig was broken globally.  Took a `zigbun.zip`
upload (pristine Zig install) to recover.  **Lesson**: scope
sed sweeps to source dirs, NEVER include `tools/` when the Zig
distribution lives there.

**Audit**:
- 174 files, 0 lint.
- All 1884/1884 host tests pass.  Stage 3 smoke fixture passes.
- All six standalones at unchanged sizes (270/274/179/295/299/5389
  KB).  No host-visible behavior change.
- Build pipeline emits ZERO `--dep shadermath` args.  Codegen-
  produced io.zig files import only `zm` (not `shadermath`).
- 13 engine shaders + 6 example shaders all use `@import("zm")`
  exclusively.

**What still exists** (but doesn't influence behavior):
- `src/shadermath.zig` on disk (~447 lines) — no shader / iface /
  io / CPU file imports it.  Per locked decision D8, full deletion
  is Stage 10 work.
- `shadermath_mod_for_zls` registered in build.zig + passed through
  ShaderPipeline.init — kept for downstream-project API
  compatibility.  External `build.zig` files calling
  `ShaderPipeline.init(b, tools, shader_iface, shadermath_mod,
  math_mod)` continue to compile; the shadermath_mod parameter is
  accepted but unused inside the pipeline.

**The unlock**: ONE math import (`zm`) gets you everything for
both CPU and shader code.  Cube_split's vertex shader, the
engine's PBR fragment shader, mandelbrot's complex-arithmetic
fragment shader, the CPU-side `rotation()` matrix math — all
import the same `math.zig`.  The cognitive load of "is this
shader math or CPU math?" is gone.

---



### Phase 0.5 (2026-05-26) — Complex numbers ✅

Total time: ~45 minutes including the mandelbrot migration.

**What landed**:
1. **`Complex = @Vector(2, f32)`** declared in zimrmath.zig as a
   SIMD alias for Vec2.  Native `+` and `-` work as complex add /
   subtract (because Complex IS a vector type) — the headline
   one-liner shape `z = cmul(z, z) + c` Just Works.
2. **Complex constants**: `c_zero`, `c_one`, `c_i`.
3. **Complex operations** (all SPIR-V-portable):
   - `complex(re, im)` constructor.
   - `cmul` (multiplication — NOT the `*` operator, which is
     componentwise on Vec2).
   - `cdiv`, `cconj`, `cnorm2`, `cabs`.
   - `carg` (routes through `atan2Scalar`, the polynomial fallback).
   - `cexp` (uses `@exp` / `@cos` / `@sin` builtins).
   - `clog` (principal branch via `@log` + `carg`).
   - `cpow(z, n)` for real exponent (via `cexp` ∘ `clog`).
   - `cmandelbrot_step(z, c) = cmul(z, z) + c` — the iteration kernel
     for both mandelbrot AND julia.  Same math, different driver
     code (mandelbrot varies `c` per-pixel; julia varies `z₀`).
4. **16 host tests** in zimrmath.zig covering: constants, constructor,
   `i² = -1`, `(1+2i)(3+4i) = -5 + 10i`, identity, `(1+i)/(1-i) = i`,
   conjugate, modulus, `|3+4i| = 5`, arg branch values (0, π/2, π),
   Euler's identity `e^(iπ) + 1 = 0`, `log(-1) = iπ`, `cpow` vs
   `cmul`, mandelbrot escape sequences (z=0,c=0 stays at 0; z=0,c=1
   diverges as 1, 2, 5).  All pass.

**Mandelbrot migration**:

Before (hand-rolled per-pixel iteration body):
```zig
const x2: f32 = zm.square(z[0]);
const y2: f32 = zm.square(z[1]);
if (x2 + y2 > 256.0) { escaped = 1; break; }
z = zm.vec2(x2 - y2 + c[0], 2.0 * z[0] * z[1] + c[1]);
```

After:
```zig
if (zm.cnorm2(z) > 256.0) { escaped = 1; break; }
z = zm.cmandelbrot_step(z, c_complex);
```

Source halved.  Reads like the textbook math.

**Visual A/B**: GLSL output is bit-identical to the pre-Phase-0.5
hand-rolled version.  spirv-opt fully inlined the `cmul` function
call and recognized the algebraic structure:
```glsl
_1836 = vec2((_1235 - _1238) + _1029, ((2.0 * _1812.x) * _1812.y) + _1040);
```
That's exactly `vec2(x² - y² + c.x, 2xy + c.y)` — same machine code,
nothing left behind by the abstraction.

**Audit**:
- 174 files, 0 lint, all tests pass (now 1900/1900 — 16 new Complex
  tests in zimrmath.zig).  Stage 3 smoke shader passes (now exercises
  `cmul` + `cnorm2` + `cmandelbrot_step` on SPIR-V; smoke fixture
  GLSL grew from 5371 to 5679 bytes).
- mandelbrot standalone unchanged at 157/270 KB.  Pixels bit-
  identical between pre- and post-Phase-0.5 builds.

**The unlock**: complex arithmetic is now a first-class citizen
for both CPU code and shader code.  Mandelbrot reads like math
papers.  Stage 7 (Julia-set explorer with mouse-controlled `c`)
can be a tiny demo built on the same primitive — same kernel,
different driver.

---



### Stage 2 (2026-05-26) — Matrix convention switch ✅

**THE dangerous window.** Per locked decision D7, all in one block,
broken-build accepted.  Total time: ~2 hours.  Window of red: ~1.5
hours.  Smaller than the 24-48h budgeted.

**The switch**:
- `Mat = [4]Vec` storage UNCHANGED.  Same 64 bytes.  What changed:
  the **interpretation**.  `Mat[i]` now means **column i**.
  Translation lives in `mat[3]` (the last column).
- Polymorphic `pub fn mul(a: anytype, b: anytype)` DELETED.
- New explicit API: `mulMat` (Mat×Mat, column-major composition),
  `mulMatVec` (M*v), `mulMatScalar` (Mat×f32), `mulMatPoint`
  (Mat×Vec3 with implied w=1).
- `mulMat(A, B)` is operand-swapped from old `mul(A, B)`: same
  arithmetic, swapped args.  This is the duality the plan
  described.  Compile errors at every call site forced the swap
  one location at a time.

**The 73-site migration**:
- 17 files: render.zig, drawing.zig, scene.zig, rlsw.zig, rlgl.zig,
  runtime.zig, types.zig, math.zig (internal callers + tests),
  tests/transform_order_test.zig, examples/rlsw_side_by_side.zig.
- Zero shaders touched.  The engine VS files
  (default_vs/lambert_vs/pbr_vs/shadow_vs/skybox_vs/unlit_vs)
  already used `mulMatPoint`/`mulMatVec` from shadermath — they
  were column-major-compatible from the start.

**Migration rules** (mechanical):
- Old `mul(M0, M1)` Mat×Mat (M0-applied-first in row-major) →
  NEW `mulMat(M1, M0)` (column-major M1-applied-after).
  Operand swap.
- Old `mul(v, M)` Vec×Mat → NEW `mulMatVec(M, v)`.  Operand swap.
- Old `mul(M, v)` Mat×Vec (rare; was transpose under row-major) →
  needs case-by-case.  No instances in the codebase.
- Old `mul(s, M)` or `mul(M, s)` (Vec×scalar) → NEW
  `mulMatScalar(M, s)`.

**One subtlety caught and re-verified**: `src/scene.zig:913`
hierarchy-fold loop.  The OLD code `world = mul(chain[i], world)`
for `i = depth-1 .. 0` built bytes that happened to be
**column-major-correct** even though `mul` itself was implemented
row-major (the operand-order "accident" the plan flagged in
Section "The duality that's been hiding in plain sight").  Under
NEW M*v, the bytes need the SAME operand order as the old code —
`world = mulMat(world, chain[i])` — NOT operand-swapped.  Caught
during analysis; comment rewritten to document the new semantic
reading explicitly.

**The transform_order_test gate**: zimr has a dedicated
`src/tests/transform_order_test.zig` (233 lines) that pins the
TRS composition order AND hierarchy-fold direction with
non-commuting matrix fixtures.  All five tests in it pass after
migration.  This is the test that originally surfaced the
"discrepancy 3" hierarchy bug per matrix-fix-plan.md; it's the
strictest gate possible on matrix convention.

**Two new public test cases in math.zig**:
1. `"mulMat composes in math order: mulMatVec(mulMat(A,B), v)
   == A*(B*v)"` — verifies the associative identity directly.
2. `"mulMatVec on translation matrix moves the point"` — verifies
   translation column convention (translation in `mat[3]`).

**Audit**:
- 175 files, 0 lint.  **All 1880+/1880+ tests pass.**  Both SPIR-V
  fixtures pass (fixture_fs 2069 bytes, math_intrinsic_smoke_fs
  15172 bytes).
- All six standalones build at **unchanged sizes**
  (270/274/179/295/299/5389 KB).  wasm bytes identical to
  pre-migration on shader-only standalones (mandelbrot, shader);
  cube_split and damaged_helmet have host-side matrix math so
  their wasm differs in instruction order but produces
  bit-identical pixel output.

**The unlock**: The "duality" between row-major + v*M vs
column-major + M*v is now collapsed.  Only ONE reading of the
matrix bytes exists in zimr: column-major, M*v.  Shaders, host
math, and storage all agree.  Future call sites can be written
naturally — "mvp = projection * view * model" in math becomes
`mulMat(projection, mulMat(view, model))` in code, reading
left-to-right exactly as the math does.

The shadermath `mulMatPoint`/`mulMatVec` functions are now
redundant with math.zig's — Stage 5 will retire them.

---



### Phase -1 (2026-05-26) — Vec2i (renamed from Vector2i) → @Vector(2, i32) ✅

Total time: ~1.5 hours including rename pass.

**Refinements during execution**:
1. Renamed `Vector2i` → `Vec2i` for math-vocabulary family
   consistency (`Vec`, `Vec2`, `Vec3`, **`Vec2i`**).
2. Added `zm.splat2i(v: i32) Vec2i` next to `splat`/`splat2`/
   `splat8`/`splatInt`.
3. Moved canonical Vec2i home to `src/math.zig`; types.zig re-exports.

**Changes**: 73 identifier sites across `src/types.zig`,
`src/rlsw.zig`, `src/rlsw_shader.zig`, `src/zimr.zig`.  Old struct
(48 lines, 6 methods) → 1-line SIMD alias + 1 inline helper.  Test
block rewritten for SIMD shape.

**One bug caught**: two `.init(0, 0)` literals with inferred type
context missed the sed pattern; build error surfaced them; fixed
to `.{ 0, 0 }`.

**Audit**: 1880+/1880+ tests, 0 lint at 174 files, six standalones
at unchanged sizes (270/274/179/295/299/5389 KB).  wasm bytes
bit-identical to pre-migration.

---

### Stage 0 (2026-05-26) — math.zig portability audit ✅

Total time: ~45 minutes including building the script + two reruns
to catch false positives.

**Audit script**: Python walks `src/math.zig`, finds every `pub fn`
/ `pub inline fn` / `pub noinline fn` declaration via regex, finds
the function end via brace tracking on **comment-stripped** lines
(critical — the first pass false-flagged `round`/`trunc`/`floor`/
`ceil` as host-only because the word "allocator" appears in their
docstring comments about "register-allocator assertion").

**Surprising finding**: math.zig has **251 functions**, not the
119 I estimated.  My initial grep used `^pub fn` and missed the
132 `pub inline fn` declarations.  Inline functions account for
more than half the surface — most of the swizzle/load/store/
predicate helpers are inline for codegen reasons.

**Final breakdown**:
- **G (gpu-safe today): 220 / 251 = 87.6%** — pure arithmetic,
  vector ops, swizzles, builders.  Compile to SPIR-V verbatim.
- **GM (gpu-fixable mechanically): 26 / 251 = 10.4%**
  - 16 use `assert()` — gate behind `comptime is_gpu` no-op
  - 8 use `std.math.X` — route through `math_intrinsic.zig` veneer
  - 2 use `@floatCast` for f16 — depends on SPIR-V f16 capability
- **H (host-only): 5 / 251 = 2.0%**
  - `fftInitUnityTable`, `fft`, `ifft` — slice mutation + @memcpy
    + internal helpers
  - `expectVecApproxEqAbs`, `expectVecEqual` — test helpers with
    error returns

**Intrinsic veneer sized**: only **5 SPIR-V-relevant intrinsics**
needed from `std.math` (the rest are integer utility / host-only
predicates): `approxEqAbs`, `asin`, `atan2`, `exp2`, `inf`.  Plus
the top-level re-exports (`pow`, `tan`, `log2`, `exp2`, `floatEps`,
`floatMax`, `signbit`, etc.) need wrapping.  Stage 1's
`math_intrinsic.zig` will be ~40-60 lines.

**The verdict**: math.zig is in MUCH better shape than I feared.
87.6% ports without touching a line.  The other 12.4% is two
straightforward sweeps (gate asserts, route std.math.X).  The plan
held up to scrutiny — and the implementation is going to be
faster than budgeted.

**Files**:
- `src/notes/math_audit.csv` — 251 rows + 18-line summary header.
  Columns: `fn_name, category, lines_of_code, src_line, notes`.
- Greppable: `grep ',G,' math_audit.csv | wc -l` shows G count;
  `grep ',GM,' | awk -F, '{print $5}' | sort | uniq -c` shows
  the GM subtype distribution.

---
### Stage 1 (2026-05-26) — math_intrinsic.zig veneer ✅ (with polynomial fallbacks)

Total time: ~1 hour including the polynomial follow-up pass.

**Files**:
- `src/math_intrinsic.zig` (~340 lines including polynomials, doc
  comments, and tests): the target-conditional veneer.
- `tests/math_intrinsic_smoke_fs.zig`: smoke shader exercising
  every transcendental in the veneer including the polynomial
  fallbacks.  Wired into `zig build test` alongside fixture_fs.

**Build wiring**:
- `src/shader_codegen.zig`'s `addShaderInternal`: every shader compile
  gets `--dep math_intrinsic` + `-Mmath_intrinsic=src/math_
  intrinsic.zig` alongside the existing shadermath dep.
- `build.zig`: matching ZLS module declaration and exe_mod imports
  for CPU-side use.

**SPIR-V limitation worked around (the key win)**: `std.math.atan` /
`asin` / `acos` use polynomial-coefficient lookup tables accessed
via `[]const f32` — SPIR-V's Logical addressing model rejects this:

```
tools/zig-x86_64-linux-0.16.0/lib/std/math/atan.zig:190:27:
error: cannot access element of logical pointer '[]const f32'
```

Initial plan: mark as "host-only-for-now" and defer to Stage 3.
But the user pointed out the obvious better answer: implement the
math ourselves in pure Zig.  Done.

**The polynomial implementations**:
- `atan(x)` on SPIR-V: degree-11 odd minimax approximation on
  `[-1, 1]` with `atan(x) = π/2 - atan(1/x)` reflection for
  `|x| > 1`.  Max abs error ≈ **3e-6 over [-1000, 1000]** (verified
  against Python's `math.atan` on 10k random samples).  That's
  ~22 bits of f32 precision — plenty for rendering.
- `atan2(y, x)` on SPIR-V: standard 4-quadrant reconstruction from
  `atan(y/x)` with sign/branch dispatch for the four quadrants
  plus the x=0 axes.  Inherits atan's error.
- `asin(x)` on SPIR-V: `atan(x / sqrt(1 - x²))` with clamping at
  `|x| = 1`.  Max error ≈ 3.4e-6 over `(-0.999, 0.999)`.
- `acos(x)` on SPIR-V: `π/2 - asin(x)`.

**Subtle bonus**: the polynomial implementations are
**target-uniform** — CPU and GPU compute the same approximation.
Hardware `atan2` (GLSL.std.450.Atan2) would be marginally faster
but would diverge from libc's `atan2` by a few LSBs.  With the
polynomials, the cube_split windowshade divider shows
bit-identical pixels at any precision level we test against.  The
shader source IS the spec; CPU and GPU run the same code.

**The future Tier 1 path**: zimr's `tools/zspv_rewrite.zig` already
does semantic SPIR-V bytecode rewriting (it replaces the
`zsample2d` placeholder with native `OpImageSampleImplicitLod`
ops).  Adding rules to replace `mi.atan2(y, x)` with a native
GLSL.std.450.Atan2 `OpExtInst` would be ~50 lines.  Deferred until
needed; the polynomial path is plenty for the math-unification
plan's demos.

**Final intrinsic veneer surface** (all work on both targets):
- Transcendentals via Zig @-builtin: `sin`, `cos`, `tan`, `sqrt`,
  `exp`, `exp2`, `log`, `log2`, `pow`
- Transcendentals via polynomial fallback on SPIR-V (std.math on
  host): `asin`, `acos`, `atan`, `atan2`
- Rounding/sign: `floor`, `ceil`, `round`, `trunc`, `abs`, `sign`
- Constants: `inf`, `nan`, `floatEps`, `floatMax`,
  `isFinite`/`isNan`/`signbit`
- Angle: `degreesToRadians`, `radiansToDegrees`
- Approx eq: `approxEqAbs`
- `assert` (no-op on SPIR-V)
- `is_gpu` (the comptime bool)

**Audit**:
- 175 files, 0 lint.  All 1880+/1880+ tests pass (now including
  the 9 math_intrinsic tests covering the polynomial fallbacks).
- TWO SPIR-V fixtures in the gate: fixture_fs (2069 bytes GLSL)
  and math_intrinsic_smoke_fs (15172 bytes GLSL — the size jump
  vs the earlier 916 bytes is the inlined polynomial bodies).
- All six standalones at unchanged sizes (270/274/179/295/299/5389
  KB) — math_intrinsic unused at runtime today.

**The unlock**: math_intrinsic now has **zero host-only paths**.
Any shader can use any function in the veneer.  Stage 3 can route
math.zig's `std.math.asin` / `atan2` / etc. through here without
caveats.  The "atan2 doesn't work on SPIR-V" concern is gone.

---



Total time: ~1.5 hours including the rename pass.  Smaller surface
than the audit expected; the actual code (rlsw.zig + rlsw_shader.zig
+ zimr.zig + types.zig) had ~73 identifier uses, not the 116 raw
grep count which included `src/notes/archive/` doc references.

**Refinements during execution**:
1. **Renamed `Vector2i` → `Vec2i`** for consistency with the rest of
   the math vocabulary (`Vec`, `Vec2`, `Vec3`).
2. **Added `zm.splat2i(v: i32) Vec2i`** next to the existing
   `splat`/`splat2`/`splat8` family.  Replaces `@as(Vec2i, @splat(N))`
   boilerplate.
3. **Moved `Vec2i` canonical home to `src/math.zig`** (sibling of
   `Vec`/`Vec2`/`Vec3`).  `src/types.zig` re-exports.

**Audit**: 1880+/1880+ tests, 0 lint at 174 files, six standalones
at unchanged sizes (270/274/179/295/299/5389 KB).  wasm bytes
bit-identical to pre-migration.

**Ergonomic verdict**: validates SIMD-vector + family-naming.
Examples:
```zig
// before:                          // after:
Vector2i.zero()                     zm.splat2i(0)
Vector2i.init(w, h)                 Vec2i{ w, h }
field.x                             field[0]
```

---

