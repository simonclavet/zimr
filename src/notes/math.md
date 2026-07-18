# `zm` — zimr's unified math library

`src/zimrmath.zig` (module name `zimrmath`, conventionally aliased
`zm`) is zimr's universal math library.  It compiles for both host
and shader (SPIR-V) targets from a single source file.  Vector,
matrix, quaternion, complex, GLSL-style helpers, SDF primitives,
and SPIR-V decorators all live here.

This document covers the public API and the conventions every
caller follows.  For implementation history see
[`math_unification.md`](math_unification.md).

## Quick start

```zig
const zm = @import("zm");

// 2D / 3D / 4D vectors — native SIMD via @Vector
const p: zm.Vec3 = zm.vec3(1.0, 2.0, 3.0);
const q: zm.Vec3 = zm.vec3(4.0, 5.0, 6.0);
const sum: zm.Vec3 = p + q;             // (5, 7, 9)
const dist: f32 = zm.length(p - q);     // √27

// 4×4 matrices, COLUMN-major, M*v multiplication
const t: zm.Mat = zm.translation(1, 2, 3);
const r: zm.Mat = zm.rotationY(0.5);
const m: zm.Mat = zm.mulMat(t, r);      // t * r  (apply r first, then t)
const moved: zm.Vec3 = zm.mulMatPoint(m, p);

// Complex numbers — SIMD-aligned Vec2 with named ops
const z: zm.Complex = zm.complex(1, 1);
const z2: zm.Complex = zm.cmul(z, z) + zm.c_i;  // (1+i)² + i
```

## What's in `zm`

### Types

| Type | Definition | Use |
|---|---|---|
| `Vec` | `@Vector(4, f32)` | 4D vectors, mat columns, quaternions |
| `Vec3` | `@Vector(3, f32)` | 3D positions, directions, colors |
| `Vec2` | `@Vector(2, f32)` | 2D positions, UVs, screen coords |
| `Vec2i` | `@Vector(2, i32)` | Pixel coordinates, viewport dims |
| `Mat` | `[4]Vec` | 4×4 matrix, column-major |
| `Quat` | `Vec` (alias) | Quaternion (x, y, z, w) |
| `Complex` | `@Vector(2, f32)` | Complex number (re, im) — SIMD alias for Vec2 |
| `F32x8`, `F32x16` | `@Vector(8/16, f32)` | Wider SIMD when needed |

### Operations

Constructors and field accessors are at the top of the file
(`vec2`, `vec3`, `vec4`, `f32x4`, `f32x8`, `f32x16`, `mat4`).
Field swizzle helpers: `sw(v, .{0, 2, 1})` for arbitrary
shuffles; named accessors `xy`, `xz`, etc. where they make
sense.

Geometry: `dot`, `cross3`, `length`, `lengthSqr`, `normalize`,
`distance`.

GLSL-style: `clamp`, `clamp01`, `mix` (lerp), `fract`,
`smoothstep`, `step`, `sign`.

Matrices (column-major, M*v):
- Construction: `identity`, `translation`, `rotationX/Y/Z`,
  `rotation` (axis-angle), `scaling`, `lookAt`, `perspective`,
  `orthographic`.
- Multiplication: `mulMat(A, B)` (matrix*matrix),
  `mulMatVec(M, v)` (matrix*Vec — applies homogeneous division
  if `v.w != 1`), `mulMatPoint(M, v)` (matrix*Vec3 — treats v as
  a point, i.e. (x, y, z, 1)), `mulMatScalar(M, s)`.
- The polymorphic `mul()` that pre-Stage-2 of math-unification
  guessed at intent is GONE.  Pick the right function for the
  operands.

Quaternions: `quat`, `quatFromEuler`, `quatToMat`, `quatMul`,
`quatNormalize`, `slerp`.

Complex: `complex(re, im)`, constants `c_zero`/`c_one`/`c_i`,
ops `cmul`, `cdiv`, `cconj`, `cnorm2`, `cabs`, `carg`, `cexp`,
`clog`, `cpow`, iteration helpers `cmandelbrot_step`.

Trig: `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`.
On host these dispatch to Zig builtins (`@sin`, `@cos`, …).
On SPIR-V the same names dispatch to `atan2Scalar`,
`asinScalar` — polynomial fallbacks that avoid `std.math.X`
lookup tables SPIR-V's Logical addressing rejects.  Vector
trig (`sin(v: Vec)`, `cos(v: Vec)`) is host-only for now — see
the Limitations section.

SDF primitives (minimal kit): `sdfBox`, `sdfSphere`, `sdfPlane`,
`sdfSmin` (smooth-min), `sdfOpUnion`, `sdfOpIntersect`,
`sdfOpSubtract`.

SPIR-V shader decorators (shader-only — these emit inline SPIR-V
asm; host-target callers get no-ops via comptime lazy elision):
- `location(&extern_var, n)` — assign a stage location/binding.
- `binding(&extern_var, set, binding)` — assign a descriptor set + binding.
- `zsample2d(&sampler, uv)` — placeholder for textureSample (rewritten
  to OpImageSampleImplicitLod by the zspv post-processing pass).

Constants: `pi`, `tau` (2π), `e`, `epsilon`.

## Conventions

### Column-major matrices, M*v multiplication

`Mat = [4]Vec` — four columns of four floats.  `mulMatVec(M, v)`
treats `v` as a column vector and computes `M * v`.  Transformations
compose left-to-right when reading the code:

```zig
const m: zm.Mat = zm.mulMat(
    zm.mulMat(translation, rotation),
    scale,
);
const transformed = zm.mulMatPoint(m, point);
// Equivalent to: translation * rotation * scale * point
// Applied right-to-left:  scale first, then rotation, then translation.
```

This matches GLSL (`gl_Position = projection * view * model * pos`)
and the linear-algebra textbooks.  Locked decision D1 of
math-unification.

### `compose` — build transforms in application order

`mulMat`'s operand order (later transform on the LEFT) is correct
but easy to reverse by accident, especially when a `lookAt*` /
`perspective*` matrix is involved or when translating code from a
library with the opposite convention.  When you're building a
transform as a *sequence of steps*, prefer `compose`, which reads
in the order things happen:

```zig
// "apply look, then spin" — reads left-to-right as it executes.
const m: zm.Mat = zm.compose(look, zm.rotationZ(angle));
// identical to, but clearer than:
const same: zm.Mat = zm.mulMat(zm.rotationZ(angle), look);

// three steps: model, then view, then projection.
const mvp: zm.Mat = zm.composeN(model, view, projection);
```

`compose(first, then) == mulMat(then, first)`; `composeN(a, b, c)
== mulMat(c, mulMat(b, a))`.  Both are covered by unit tests in
`zimrmath.zig` ("compose applies first, then second …").  Use
`mulMat` directly only where the `proj * view * model` reading is
already the natural one (e.g. a single `view_proj = mulMat(proj,
view)`); use `compose`/`composeN` for everything sequential.

### ⚠ Porting matrix code from raylib

raylib is the single biggest source of matrix-convention bugs in
this codebase because it uses the OPPOSITE multiplication order.
raylib's `MatrixMultiply(left, right)` is row-vector — it applies
`left` FIRST, then `right` (a point is `v * left * right`).  zm's
`mulMat(a, b)` applies `b` first, then `a`.  So:

| raylib | correct zm translation |
|---|---|
| `MatrixMultiply(A, B)` | `mulMat(B, A)`  — operands SWAPPED |
| `MatrixMultiply(A, B)` | `compose(A, B)` — operands SAME (preferred) |

**Copying raylib's operand order verbatim into `mulMat` silently
reverses the composition.**  It compiles, and often *looks* nearly
right, then places or orients geometry wrongly.  This bit the
`decals` port: raylib's `MatrixMultiply(splat, MatrixRotateZ(a))`
was first written `mulMat(splat, rotationZ(a))` (wrong — spin
applied in world space, decals flung across the scene) and should
have been `compose(splat, rotationZ(a))` (equivalently
`mulMat(rotationZ(a), splat)`).

Because `compose` shares raylib's argument order, the safest
mechanical rule when porting is: **replace `MatrixMultiply` with
`compose`, keeping the operands in the same order.**  Also note
raylib's `MatrixRotateXYZ` bakes in NEGATED angles for its
handedness — match the *behaviour* (which control moves which way),
not the matrix bytes.

### std140 padding in UBO structs

Uniform Buffer Objects on the GPU must follow std140 layout:
- `vec2` is 8-byte aligned.
- `vec3` is 16-byte aligned (and 12-byte sized, leaving a gap).
- `vec4` and `mat4` are 16-byte aligned.
- The whole UBO struct size must round to 16 bytes.

Host-side UBO structs in zimr use explicit `_padN: f32 = 0`
fields to enforce the right offsets.  `UniformBuffer(T)` runs a
comptime check that `@sizeOf(T) % 16 == 0` as a safety net.
Example from `examples/julia_fs.zig`:

```zig
pub const Ubo = extern struct {
    center: zm.Vec2,    // offset 0
    zoom: f32,          // offset 8
    _pad0: f32 = 0,     // offset 12 — vec2 below needs 8-byte align
    resolution: zm.Vec2, // offset 16
    max_iter: f32,      // offset 24
    _pad1: f32 = 0,     // offset 28
    julia_c: zm.Vec2,   // offset 32
    _pad2: f32 = 0,     // offset 40
    _pad3: f32 = 0,     // offset 44 — round to 48 (multiple of 16)
};
```

### Quaternion product order (Hamilton)

`qmul(a, b)` is the **Hamilton** product: it applies `b` first, then `a`, so it
composes the SAME way as matrices and as Jolt:

```zig
matFromQuat(qmul(a, b)) == mulMat(matFromQuat(a), matFromQuat(b));
rotate(qmul(a, b), v)   == rotate(a, rotate(b, v));
```

This means a Jolt expression `q = a * b` ports **literally** to `qmul(a, b)` — no
operand reversal. Internally `qmul` wraps zmath's SIMD kernel (`qmulRaw`), which
composes the opposite way, by swapping the operands; callers never touch `qmulRaw`.

This was Stage-1 of the 2026-06 quaternion-convention unification: zmath's kernel
originally composed left-to-right (`qmul(a,b)` = apply a then b), which disagreed
with the matrix convention (D1) and with Jolt, and was a standing source of
operand-order bugs in the physics port (e.g. the world-vs-body frame error in
`integrateRotation`). The flip + a behaviour-preserving operand swap at every call
site made quaternion and matrix composition agree. Locked decision.

### Quaternions store as (x, y, z, w)

`Quat = Vec`, layout (x, y, z, w).  Locked decision D9 of
math-unification.  The `w`-first convention you see in some
graphics codebases doesn't match GLSL or Zig's `Vec`/`Vec3`
field order; (x, y, z, w) is the consistent choice.

### Complex numbers and the `*` operator gotcha

`Complex = @Vector(2, f32)` (same storage as `Vec2`).  Native
`+` and `-` work as complex addition / subtraction.  But the
native `*` operator on `Complex` does **componentwise**
multiplication, NOT the complex product.

```zig
const a = zm.complex(1, 2);
const b = zm.complex(3, 4);

const wrong: zm.Complex = a * b;       // (3, 8)  — componentwise
const right: zm.Complex = zm.cmul(a, b); // (-5, 10) — complex product
```

Same trap for `/` (use `cdiv`).  Locked decision D3 of
math-unification: keep the SIMD alias for the codegen wins and
discipline the call site via the named functions.

## Limitations

- **Vector trig on SPIR-V**: `sin(v: Vec)`, `cos(v: Vec)`,
  `atan(v: Vec)` are not yet GPU-portable.  zmath's
  implementation does `@bitCast(Vec, @Vector(4, u32))` for
  sign-bit manipulation, which SPIR-V's Logical addressing
  model rejects.  Rewriting the int-op family (33 call sites)
  to use componentwise scalar bitcasts is post-plan work.
  Shader code that needs trig should use the SCALAR forms
  (`zm.atan2(f32, f32)`, `zm.asin(f32)`) which route through
  the polynomial fallbacks.

- **`std.math.X` for transcendentals is unavailable on SPIR-V**.
  Use Zig builtins (`@sqrt`, `@sin`, `@cos`, `@exp`, `@log`) or
  zm's polynomial fallbacks.  `@log(x)` and `@exp(x)` lower to
  `OpExtInst GLSL.std.450` ops; `std.math.log`/`std.math.exp`
  use lookup tables Logical addressing rejects.

- **`pow(x, y)` is rewritten as 2-arg `@exp(@log(x) * y)`** on the
  SPIR-V path because `std.math.pow`'s f64 path SPIR-V rejects.
  This is in `zm.pow` already — just call it.

- **`bool` storage**: Zig's SPIR-V codegen emits `bool` as
  `u1`/`uint8_t`, which WebGL2 rejects.  Use `u32` flags
  (`var escaped: u32 = 0`) inside shader bodies.

## Shader-side ergonomics

Inside a shader source file:

```zig
const zm = @import("zm");

// iface declarations at top of file (the default — see
// math_unification.md "Inline-iface as default" entry)
pub const Inputs = struct {
    frag_tex_coord: zm.Vec2,
    frag_color: zm.Vec,
};
pub const Outputs = struct {
    out_color: zm.Vec,
};
pub const Ubo = extern struct {
    /* … */
};

// body
const io = @import("<basename>_fs_io");
pub const Io = io.IoT(Ubo);
pub const Out = io.Out;
pub const iface = @This();

pub fn shaderMain(io_in: Io) Out {
    // io_in.frag_tex_coord, io_in.u.<ubo_field>, etc.
}

comptime {
    _ = io.installSpirvEntry(shaderMain);
}
```

Naming: `pub fn shaderMain` (NOT `main`).  Zig's `std.start.zig`
auto-exports `_start` when the root module declares `main`, and
`_start` requires `callconv(.naked)` which the SPIR-V backend
rejects.  Different name keeps std.start dormant.

`pub fn` (not `pub inline fn`).  Forcing inline at the Zig level
breaks the SPIR-V structured-control-flow markers; spirv-opt's
`-O` pass does the inlining post-codegen.

## Host-side ergonomics

Inside a CPU example:

```zig
const z = @import("zimr");
const iface = @import("my_fs.zig"); // shader file IS its own iface

const State = struct {
    loaded: z.shader.LoadedShader(iface),
    // …
};

fn initState(gpa, f, s) !void {
    s.loaded = try z.shader.loadShaderWithUbo(
        iface, f.gl, gpa,
        "" /* default VS */,
        @embedFile("my_fs.glsl"),
        .{ /* initial Ubo values */ },
        0 /* binding */,
    );
}

fn update(f, s) void {
    s.loaded.ub.push(.{ /* updated Ubo */ });
    z.beginShaderMode(f.gl, s.loaded.shader);
    z.drawRectangle(/* … */);
    z.endShaderMode(f.gl);
}
```

The same `iface.Ubo` type flows to both sides — the shader
body reads `io_in.u.field`, the host writes `.field = value` to
the same struct.  Drift is impossible because there's only one
declaration.

## History

This module went through ten stages of unification.  See
[`math_unification.md`](math_unification.md) for the full log,
including:

- The `shadermath.zig` → `zm` migration (Stages 3, 5, 10).
  shadermath was the original GPU-side math library; zm absorbs
  its job.  Deleted Stage 10 (2026-05-27).
- The matrix-API switch from polymorphic `mul()` to explicit
  `mulMat` / `mulMatVec` / `mulMatScalar` / `mulMatPoint` (Stage 2).
- Complex numbers as a first-class citizen (Phase 0.5).
- Iface co-location: inline iface as default for shader files
  (build.zig 2026-05-27 refactor).

If you're touching `zm`, read the
[locked decisions](math_unification.md#decisions-locked) first.
Many design choices are deliberate trade-offs that took multiple
sessions to settle.

## Compound / decorator child composition order (2026-06)

Child-into-parent rotation composition is always `qmul(parent_world_rot, child_local_rot)`
— parent is the OUTER (first) arg, child local is the INNER (second). This matches `qmul`'s
convention (first arg applied last/outer) and the inertia composition
`qmul(child.local_rot, inertia_rotation)` (child placement outer, shape's intrinsic rotation inner).

Verified empirically: for a compound disk (child rot = 90deg about X) + spoke (child rot = identity)
spun about Z, the disk-axis . spoke-axis dot stays constant (rigidly attached) ONLY with
`qmul(rot, child.local_rot)`; the reversed order makes it vary (the spoke visibly drifts vs the disk).

Fixed reversed sites: render.zig compound + rotated_translated children; zimrphysics.zig
compound-vs-compound collision (both-compound branch) and the rotated_translated shape resolver.
The single-compound collision branches and inertia composition were already correct.
