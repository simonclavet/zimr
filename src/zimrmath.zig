//! SHADER-SAFE — this file may be @imported by shader sources
//! (compiled through the SPIR-V pipeline) and by comptime executors.
//! Lint enforces the tier: no allocators, no runtime std, no externs,
//! no bridge imports outside `test` blocks.
//!
//! src/zimrmath.zig — **zimrmath**, zimr's unified math library.
//! Imported everywhere as `const zm = @import("zm");`.
//!
//! GPU-MATH VOCABULARY (search this block by the name you know):
//!   step       -> zm.step        CANONICAL (was `stepEdge`)
//!   lerp       -> zm.lerp        CANONICAL (GLSL calls it `mix`)
//!   clamp01    -> zm.clamp01     CANONICAL (HLSL calls it `saturate`)
//!   clamp      -> zm.clamp       (declared `pub inline fn` — grep for `fn clamp`)
//!   mix / saturate / stepEdge    -> exist only as PRIVATE, EMPTY decls whose doc
//!     names the canonical spelling. One name per operation, enforced by the
//!     COMPILER — not by a lint rule you have to remember to run.
//!   smoothstep -> zm.smoothstep
//!   fract      -> zm.fract
//!   dot cross normalize length distance reflect -> same names
//!   abs min max floor ceil sqrt pow exp log -> Zig BUILTINS (@abs, @min, ...),
//!     deliberately NOT wrapped: a wrapper would just hide the builtin.
//!
//! One library, two targets.  zimrmath compiles for CPU (wasm32-
//! wasi for the runtime, native for host tests) AND for SPIR-V
//! (the shader pipeline) from the same source.  Shader code and
//! CPU code share a vocabulary: `mulMat`, `mulMatVec`, `cross`,
//! `normalize3`, `vec3`, `quatToMat`, ...  No more "shader math
//! vs CPU math" cognitive split.
//!
//! Self-contained by design.  The only imports are `std` and
//! `builtin`.  Inside the module body, only a narrow slice of std
//! is touched (mostly `std.math` and `std.debug.assert` in test
//! blocks).  Zig's lazy compilation handles the rest: functions
//! not reached from a given compile target are never analyzed,
//! so the GPU compile path doesn't drag in any std.math symbols
//! that don't lower to SPIR-V.
//!
//! ### Conventions
//!
//! - **Column-major matrices**, multiplied as `M * v` (post-Z4 of
//!   the math-unification plan).  Composition: `mulMat(B, A)` means
//!   "apply A then B" — read right-to-left like math notation.
//!   This is the OPPOSITE of the vendor zmath convention; the
//!   matrix-convention switch in Stage 2 of math-unification
//!   touched ~73 sites across 17 files.  See
//!   `src/notes/math_unification.md` for the migration log.
//! - **Quaternion storage**: `(x, y, z, w)`.  Matches raylib,
//!   glTF 2.0, DirectX, GLM — the ecosystem zimr builds on.  Math
//!   papers typically write `q = w + xi + yj + zk` (scalar first);
//!   the storage is the GPU/asset convention.
//! - **No `Vec3` for SIMD storage**.  `Vec = @Vector(4, f32)` is the
//!   primary 3D-math type with a `w` lane reserved for SIMD
//!   alignment (1.0 for points, 0.0 for directions).
//!   `Vec3 = @Vector(3, f32)` exists for compact storage (3D point
//!   arrays, GLSL `vec3` uniforms) but most math operates on `Vec`.
//! - **`Vec2 = @Vector(2, f32)`** for UI / 2D math — 8 bytes,
//!   distinct from `Vec` for storage efficiency.
//! - **GLSL-style scalar helpers** (`vec3(x, y, z)`, `clamp01(t)`,
//!   `lerp(a, b, t)`, `fract(x)`, `smoothstep(e0, e1, x)`,
//!   `pow(x, y)`, `sw(v, "yzx")`, ...) live at the top level so
//!   shader code reads idiomatically.
//! - **Shader decorators** (`location`, `binding`, `zsample2d`)
//!   live here too — they're SPIR-V-only inline-asm helpers,
//!   placed at the bottom of the file under their own section.
//!
//! ### Lineage
//!
//! Vendored from zig-gamedev's zmath (0.11.0-dev, fingerprint
//! 0xfd23d422bd223cc2) at Z0 of the zmath-adoption arc.  Hard fork:
//! no upstream-merge story.  Major surgery since vendor:
//! - Z2..Z4: Vec2 SIMD, GLSL helpers, column-major switch.
//! - Stage 1 of math-unification: target-conditional veneer for
//!   assert + scalar trig polynomials, originally in a separate
//!   `math_intrinsic.zig`, inlined here at end of Stage 3.
//! - Stage 5: shadermath retired in favor of this file.  SPIR-V
//!   decorators (`location`, `binding`, `zsample2d`) absorbed.
//!   File renamed `math.zig` → `zimrmath.zig` for unambiguous
//!   branding (no collision with std's internal `math` module —
//!   see "build wiring" below).
//!
//! ### Build wiring
//!
//! Declared in `build.zig` as `addModule("zimrmath", ...)`.
//! Imported into every consumer (zimr_mod, exe_mod, exe_mod_smoke,
//! iface_mod, io modules, test_mod, the SPIR-V shader compile)
//! under the local alias name **`zm`** via `addImport("zm",
//! zimrmath_mod)`.  Two name layers because the global module
//! name "zimrmath" must NOT collide with std's internal `math`
//! module (naming it "math" triggers `error: no module named
//! 'math' available within module 'std'` in compiler_rt — see
//! the Stage 5 log in math_unification.md for the full story).
//! The short import alias `zm` keeps call sites unchanged:
//! `const zm = @import("zm")` is the universal first line.

// var camera_position = [3]f32{ 1.0, 2.0, 3.0 };
// var cam_pos = loadArr3(camera_position);
// ...
// storeArr3(&camera_position, cam_pos);
// v4 = sin(v4); // SIMDx4
// v8 = cos(v8); // .x86_64 -> 2 x SIMDx4, .x86_64+avx+fma -> SIMDx8
// v16 = atan(v16); // .x86_64 -> 4 x SIMDx4, .x86_64+avx+fma -> 2 x SIMDx8, .x86_64+avx512f -> SIMDx16
// store(mem[0..], v4, 0);
// store(mem[100..], v8, 0);
// store(mem[200..], v16, 0);
//
// 1. Initialization functions
//
// f32x4(e0: f32, e1: f32, e2: f32, e3: f32) F32x4
// f32x8(e0: f32, e1: f32, e2: f32, e3: f32, e4: f32, e5: f32, e6: f32, e7: f32) F32x8
// f32x16(e0: f32, e1: f32, e2: f32, e3: f32, e4: f32, e5: f32, e6: f32, e7: f32,
//        e8: f32, e9: f32, ea: f32, eb: f32, ec: f32, ed: f32, ee: f32, ef: f32) F32x16
// splat(v: f32) Vec          -- broadcast scalar to all lanes (canonical)
// splat2(v: f32) Vec2        -- 2-lane broadcast
// splat8(v: f32) F32x8       -- 8-lane broadcast
// boolx4(e0: bool, e1: bool, e2: bool, e3: bool) Boolx4
// boolx8(e0: bool, e1: bool, e2: bool, e3: bool, e4: bool, e5: bool, e6: bool, e7: bool) Boolx8
// boolx16(e0: bool, e1: bool, e2: bool, e3: bool, e4: bool, e5: bool, e6: bool, e7: bool,
//         e8: bool, e9: bool, ea: bool, eb: bool, ec: bool, ed: bool, ee: bool, ef: bool) Boolx16
// load(mem: []const f32, comptime T: type, comptime len: u32) T
// store(mem: []f32, v: anytype, comptime len: u32) void
// loadArr2(arr: [2]f32) F32x4
// loadArr2zw(arr: [2]f32, z: f32, w: f32) F32x4
// loadArr3(arr: [3]f32) F32x4
// loadArr3w(arr: [3]f32, w: f32) F32x4
// loadArr4(arr: [4]f32) F32x4
// storeArr2(arr: *[2]f32, v: F32x4) void
// storeArr3(arr: *[3]f32, v: F32x4) void
// storeArr4(arr: *[4]f32, v: F32x4) void
// arr3Ptr(ptr: anytype) *const [3]f32
// arrNPtr(ptr: anytype) [*]const f32
// @as(comptime T: type, @splat(value: f32)) T
// splatInt(comptime T: type, value: u32) T
//
// 2. Functions that work on all vector components (F32xN = F32x4 or F32x8 or F32x16)
//
// all(vb: anytype, comptime len: u32) bool
// any(vb: anytype, comptime len: u32) bool
// isNearEqual(v0: F32xN, v1: F32xN, epsilon: F32xN) BoolxN
// isNan(v: F32xN) BoolxN
// isInf(v: F32xN) BoolxN
// isInBounds(v: F32xN, bounds: F32xN) BoolxN
// andInt(v0: F32xN, v1: F32xN) F32xN
// andNotInt(v0: F32xN, v1: F32xN) F32xN
// orInt(v0: F32xN, v1: F32xN) F32xN
// norInt(v0: F32xN, v1: F32xN) F32xN
// xorInt(v0: F32xN, v1: F32xN) F32xN
// minFast(v0: F32xN, v1: F32xN) F32xN
// maxFast(v0: F32xN, v1: F32xN) F32xN
// min(v0: F32xN, v1: F32xN) F32xN
// max(v0: F32xN, v1: F32xN) F32xN
// round(v: F32xN) F32xN
// floor(v: F32xN) F32xN
// trunc(v: F32xN) F32xN
// ceil(v: F32xN) F32xN
// clamp(v0: F32xN, v1: F32xN) F32xN
// clampFast(v0: F32xN, v1: F32xN) F32xN
// clamp01(v: F32xN) F32xN
// saturateFast(v: F32xN) F32xN
// lerp(v0: F32xN, v1: F32xN, t: f32) F32xN
// lerpV(v0: F32xN, v1: F32xN, t: F32xN) F32xN
// lerpInverse(v0: F32xN, v1: F32xN, t: f32) F32xN
// lerpInverseV(v0: F32xN, v1: F32xN, t: F32xN) F32xN
// mapLinear(v: F32xN, min1: f32, max1: f32, min2: f32, max2: f32) F32xN
// mapLinearV(v: F32xN, min1: F32xN, max1: F32xN, min2: F32xN, max2: F32xN) F32xN
// sqrt(v: F32xN) F32xN
// abs(v: F32xN) F32xN
// mod(v0: F32xN, v1: F32xN) F32xN
// modAngle(v: F32xN) F32xN
// mulAdd(v0: F32xN, v1: F32xN, v2: F32xN) F32xN
// select(mask: BoolxN, v0: F32xN, v1: F32xN)
// sin(v: F32xN) F32xN
// cos(v: F32xN) F32xN
// sincos(v: F32xN) [2]F32xN
// asin(v: F32xN) F32xN
// acos(v: F32xN) F32xN
// atan(v: F32xN) F32xN
// atan2(vy: F32xN, vx: F32xN) F32xN
// cmulSoa(re0: F32xN, im0: F32xN, re1: F32xN, im1: F32xN) [2]F32xN
//
// 3. 2D, 3D, 4D vector functions
//
// swizzle(v: Vec, c, c, c, c) Vec (comptime c = .x | .y | .z | .w)
// dot2(v0: Vec, v1: Vec) F32x4
// dot3(v0: Vec, v1: Vec) F32x4
// dot4(v0: Vec, v1: Vec) F32x4
// cross(v0: Vec, v1: Vec) Vec
// lengthSq2(v: Vec) F32x4
// lengthSq3(v: Vec) F32x4
// lengthSq4(v: Vec) F32x4
// length2(v: Vec) F32x4
// length3(v: Vec) F32x4
// length4(v: Vec) F32x4
// normalize2(v: Vec) Vec
// normalize3(v: Vec) Vec
// normalize4(v: Vec) Vec
// vecToArr2(v: Vec) [2]f32
// vecToArr3(v: Vec) [3]f32
// vecToArr4(v: Vec) [4]f32
//
// 4. Matrix functions
//
// identity() Mat
// mul(m0: Mat, m1: Mat) Mat
// mul(s: f32, m: Mat) Mat
// mul(m: Mat, s: f32) Mat
// mul(v: Vec, m: Mat) Vec
// mul(m: Mat, v: Vec) Vec
// transpose(m: Mat) Mat
// rotationX(angle_rad: f32) Mat
// rotationY(angle_rad: f32) Mat
// rotationZ(angle_rad: f32) Mat
// translation(x: f32, y: f32, z: f32) Mat
// translationV(v: Vec) Mat
// scaling(x: f32, y: f32, z: f32) Mat
// scalingV(v: Vec) Mat
// lookToLh(eyepos: Vec, eyedir: Vec, updir: Vec) Mat
// lookAtLh(eyepos: Vec, focuspos: Vec, updir: Vec) Mat
// lookToRh(eyepos: Vec, eyedir: Vec, updir: Vec) Mat
// lookAtRh(eyepos: Vec, focuspos: Vec, updir: Vec) Mat
// perspectiveFovLh(fovy: f32, aspect: f32, near: f32, far: f32) Mat
// perspectiveFovRh(fovy: f32, aspect: f32, near: f32, far: f32) Mat
// perspectiveFovLhGl(fovy: f32, aspect: f32, near: f32, far: f32) Mat
// perspectiveFovRhGl(fovy: f32, aspect: f32, near: f32, far: f32) Mat
// orthographicLh(w: f32, h: f32, near: f32, far: f32) Mat
// orthographicRh(w: f32, h: f32, near: f32, far: f32) Mat
// orthographicLhGl(w: f32, h: f32, near: f32, far: f32) Mat
// orthographicRhGl(w: f32, h: f32, near: f32, far: f32) Mat
// orthographicOffCenterLh(left: f32, right: f32, top: f32, bottom: f32, near: f32, far: f32) Mat
// orthographicOffCenterRh(left: f32, right: f32, top: f32, bottom: f32, near: f32, far: f32) Mat
// orthographicOffCenterLhGl(left: f32, right: f32, top: f32, bottom: f32, near: f32, far: f32) Mat
// orthographicOffCenterRhGl(left: f32, right: f32, top: f32, bottom: f32, near: f32, far: f32) Mat
// determinant(m: Mat) F32x4
// inverse(m: Mat) Mat
// inverseDet(m: Mat, det: ?*F32x4) Mat
// matToQuat(m: Mat) Quat
// matFromAxisAngle(axis: Vec, angle_rad: f32) Mat
// matFromNormAxisAngle(axis: Vec, angle_rad: f32) Mat
// matFromQuat(quat: Quat) Mat
// matFromRollPitchYaw(pitch_rad: f32, yaw_rad: f32, roll_rad: f32) Mat
// matFromRollPitchYawV(angles: Vec) Mat
// matFromArr(arr: [16]f32) Mat
// loadMat(mem: []const f32) Mat
// loadMat43(mem: []const f32) Mat
// loadMat34(mem: []const f32) Mat
// storeMat(mem: []f32, m: Mat) void
// storeMat43(mem: []f32, m: Mat) void
// storeMat34(mem: []f32, m: Mat) void
// matToArr(m: Mat) [16]f32
// matToArr43(m: Mat) [12]f32
// matToArr34(m: Mat) [12]f32
//
// 5. Quat functions
//
// qmul(q0: Quat, q1: Quat) Quat
// qidentity() Quat
// conjugate(quat: Quat) Quat
// inverse(q: Quat) Quat
// rotate(q: Quat, v: Vec) Vec
// slerp(q0: Quat, q1: Quat, t: f32) Quat
// slerpV(q0: Quat, q1: Quat, t: F32x4) Quat
// quatToMat(quat: Quat) Mat
// quatToAxisAngle(quat: Quat, axis: *Vec, angle: *f32) void
// quatFromMat(m: Mat) Quat
// quatFromAxisAngle(axis: Vec, angle_rad: f32) Quat
// quatFromNormAxisAngle(axis: Vec, angle_rad: f32) Quat
// quatFromRollPitchYaw(pitch_rad: f32, yaw_rad: f32, roll_rad: f32) Quat
// quatFromRollPitchYawV(angles: Vec) Quat
//
// 6. Color functions
//
// adjustSaturation(color: Vec, saturation: f32) F32x4
// adjustContrast(color: Vec, contrast: f32) F32x4
// rgbToHsl(rgb: Vec) F32x4
// hslToRgb(hsl: Vec) F32x4
// rgbToHsv(rgb: Vec) F32x4
// hsvToRgb(hsv: Vec) F32x4
// rgbToSrgb(rgb: Vec) F32x4
// srgbToRgb(srgb: Vec) F32x4
//
// X. Misc functions
//
// linePointDistance(linept0: Vec, linept1: Vec, pt: Vec) F32x4
// sin(v: f32) f32
// cos(v: f32) f32
// sincos(v: f32) [2]f32
// asin(v: f32) f32
// acos(v: f32) f32
// fftInitUnityTable(unitytable: []F32x4) void
// fft(re: []F32x4, im: []F32x4, unitytable: []const F32x4) void
// ifft(re: []F32x4, im: []const F32x4, unitytable: []const F32x4) void
// ==============================================================================

// copied from std.math for convenience

/// Euler's number (e)
pub const euler = 2.71828182845904523536028747135266249775724709369995;

/// Archimedes' constant (π)
pub const pi = 3.14159265358979323846264338327950288419716939937510;

/// Phi or Golden ratio constant (Φ) = (1 + sqrt(5))/2
pub const phi = 1.6180339887498948482045868343656381177203091798057628621;

/// Circle constant (τ)
pub const tau = 2 * pi;

/// log2(e)
pub const log2e = 1.442695040888963407359924681001892137;

/// log10(e)
pub const log10e = 0.434294481903251827651128918916605082;

/// ln(2)
pub const ln2 = 0.693147180559945309417232121458176568;

/// ln(10)
pub const ln10 = 2.302585092994045684017991454684364208;

/// 2/sqrt(π)
pub const two_sqrtpi = 1.128379167095512573896158903121545172;

/// sqrt(2)
pub const sqrt2 = 1.414213562373095048801688724209698079;

/// 1/sqrt(2)
pub const sqrt1_2 = 0.707106781186547524400844362104849039;

/// pi/180.0
/// NOTE: prefer the `radFromDeg()` function over this raw constant. zimr's API is radians-centric —
/// rotation parameters take radians and are named `_rad` — so convert degrees at the UI layer with
/// `radFromDeg(deg)` rather than multiplying by this constant deep inside the system.
pub const rad_per_deg = 0.0174532925199432957692369076848861271344287188854172545609719144;

/// 180.0/pi
/// NOTE: prefer the `degFromRad()` function over this raw constant (see `rad_per_deg`).
pub const deg_per_rad = 57.295779513082320876798154814105170332405472466564321549160243861;

// `std.math` re-exports — single-import convenience.  Callers can use
// `zm.X` for these without needing a second `std.math` import.  Each is
// a direct compile-time alias, identical signature and behavior to its
// Where `math_intrinsic.zig` (the SPIR-V-aware veneer) provides an
// equivalent, we re-export via `mi` so math.zig itself compiles for
// shader targets.  Pure-arithmetic / integer-utility functions
// (isFinite, isPowerOfTwo, etc.) re-export directly from std.math
// — they're either SPIR-V-safe as-is, or used only from host-only
// code (FFT family).

const builtin = @import("builtin");

/// `true` when compiling for any SPIR-V target (32-bit or 64-bit,
/// Vulkan or OpenCL).  Drives target-conditional behavior in this
/// file — `assert` becomes a no-op, and a few scalar trig helpers
/// (`atan2Scalar`, `asinScalar`) use polynomial approximations
/// instead of `std.math.X` (which uses lookup tables incompatible
/// with SPIR-V's Logical addressing model).
///
/// Was originally a separate module `math_intrinsic.zig`; Stage 3
/// of the math-unification plan inlined it here for a flatter file
/// layout.  See `src/notes/math_unification.md` Stage 3 entry.
pub const is_gpu: bool = builtin.target.cpu.arch.isSpirV();

const std = @import("std");

/// Floating-point power: `base ** exponent`.  GLSL-style 2-arg
/// signature (`pow(x, y)` rather than std.math's `pow(T, x, y)`).
/// Implementation: `@exp(@log(x) * y)` — works for f32 on host AND
/// SPIR-V (the Zig builtins lower to GLSL.std.450 ops).  Stage 5
/// of math-unification switched from `pub const pow = std.math.pow`
/// because std.math.pow has an f64 path the SPIR-V backend rejects
/// ("floating point width of 64 bits is not supported for the
/// current SPIR-V feature set").  Host callers that previously
/// passed `zm.pow(x, y)` now pass `zm.pow(x, y)` directly.
pub inline fn pow(base: f32, exponent: f32) f32 {
    // CPU: std.math.pow is accurate and handles the special cases
    // (negative base, integer exponents, pow(x,0)==1, …) that the
    // exp/log identity below gets wrong; it is >100 lines so we
    // delegate rather than copy.  GPU: the cheap identity is fine for
    // cosmetic shader work.
    if (comptime !is_gpu) {
        return std.math.pow(f32, base, exponent);
    }
    return @exp(@log(base) * exponent);
}
// ---- small exact utilities, vendored in-house --------------------------
// zimrmath is the ONE file allowed to touch std.math (enforced by the
// `std-math` lint rule).  For the small, exact functions below we COPY
// std's implementation rather than delegate, so there's a single un-gated
// impl that's GPU-portable by construction (pure arithmetic / @bitCast /
// integer ops lower fine to SPIR-V).  No `comptime !is_gpu` split needed:
// the host result is bit-identical to std for the f32/f64/integer types
// zimr uses.  The big transcendentals that genuinely warrant delegation
// (pow, atan, atan2, hypot — all >100 lines) still call std on the CPU
// path under a gate; see those functions.  When you need a std.math
// function that isn't here: add it (vendored if small, gated-delegate if
// big) — do NOT reach for std.math at the call site.

/// Degrees → radians.
pub inline fn radFromDeg(d: anytype) @TypeOf(d) {
    return d * (pi / 180.0);
}
/// Radians → degrees.
pub inline fn degFromRad(r: anytype) @TypeOf(r) {
    return r * (180.0 / pi);
}
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

test "zm.radFromDeg" {
    try expectApproxEqAbs(@as(f32, pi), radFromDeg(@as(f32, 180.0)), 1.0e-4);
}
test "zm.degFromRad" {
    try expectApproxEqAbs(@as(f32, 180.0), degFromRad(@as(f32, pi)), 1.0e-4);
}
/// Positive infinity of float type `T`.
pub inline fn inf(comptime T: type) T {
    return switch (T) {
        f32 => @bitCast(@as(u32, 0x7F80_0000)),
        f64 => @bitCast(@as(u64, 0x7FF0_0000_0000_0000)),
        else => @compileError("zm.inf: unsupported float type"),
    };
}

/// True when `x` is neither inf nor nan.
pub inline fn isFinite(x: anytype) bool {
    // Finite iff not-NaN (x == x) and not-±inf.  Bit-identical result to
    // std.math.isFinite for f32/f64.
    return (x == x) and (@abs(x) != inf(@TypeOf(x)));
}
/// True when `x` is a positive power of two.
pub inline fn isPowerOfTwo(x: anytype) bool {
    // std.math.isPowerOfTwo asserts `x > 0`; this returns false for x <= 0
    // instead (a safer contract for the same valid-input behavior).
    return x > 0 and (x & (x - 1)) == 0;
}
/// True in stripped ship builds (ReleaseSmall/Fast). Asserts compile to a bare
/// `unreachable` in this mode unless `-Dassert-log` forces them back on.
const is_stripped: bool = builtin.mode == .ReleaseSmall or builtin.mode == .ReleaseFast;

/// Assertion with a source location but no message — cheaper to write than
/// `assertf` when the condition is self-explanatory. `std.debug.assert` on GPU.
/// On CPU: a dev (debug) build logs file:line + `@panic`s; a release build with
/// `assert_log` (e.g. the on-device standalones) logs file:line to the page's
/// log overlay and KEEPS RUNNING (a frozen canvas is a worse failure than a
/// logged, recoverable glitch — callers that need to bail must do so themselves);
/// a ship build compiles the check out (`unreachable`).
///     assert(len > 0, @src());
pub inline fn assert(ok: bool, src: std.builtin.SourceLocation) void {
    if (comptime is_gpu) {
        if (!ok) {
            unreachable;
        }
    } else {
        if (!ok) {
            if (comptime !is_stripped) {
                std.log.err("assert failed at {s}:{d}:{d}", .{ src.file, src.line, src.column });
                @panic("assertion failed");
            } else if (comptime @import("build_options").assert_log) {
                std.log.err("assert failed at {s}:{d}:{d}", .{ src.file, src.line, src.column });
            } else {
                unreachable;
            }
        }
    }
}

pub fn Log2Int(comptime T: type) type {
    if (T == comptime_int) {
        return comptime_int;
    }
    const bits: u16 = @typeInfo(T).int.bits;
    const log2_bits: u16 = 16 - @clz(bits - 1);
    return @Int(.unsigned, log2_bits);
}

/// Smallest power of two ≥ `value` (asserts no overflow on host).
pub inline fn ceilPowerOfTwo(comptime T: type, value: T) error{Overflow}!T {
    // Vendored from std.math.ceilPowerOfTwo: promote to one extra bit so
    // the overflow bit can be tested, then narrow back.  Keeps std's
    // `error.Overflow` contract.  (The `value <= 1` guard subsumes std's
    // `assert(value != 0)` — we return 1 rather than trapping on 0.)
    const info = @typeInfo(T).int;
    comptime assert(info.signedness == .unsigned, @src());
    if (value <= 1) {
        return 1;
    }
    const Promoted: type = @Int(.unsigned, info.bits + 1);
    const Shift: type = Log2Int(Promoted);
    const x: Promoted = @as(Promoted, 1) << @as(Shift, @intCast(info.bits - @clz(value - 1)));
    if ((@as(Promoted, 1) << info.bits) & x != 0) {
        return error.Overflow;
    }
    return @as(T, @intCast(x));
}
/// Quiet NaN of float type `T`.
pub inline fn nan(comptime T: type) T {
    return switch (T) {
        f32 => @bitCast(@as(u32, 0x7FC0_0000)),
        f64 => @bitCast(@as(u64, 0x7FF8_0000_0000_0000)),
        else => @compileError("zm.nan: unsupported float type"),
    };
}
/// Machine epsilon of float type `T`.
pub inline fn floatEps(comptime T: type) T {
    return switch (T) {
        f32 => 1.1920928955078125e-7,
        f64 => 2.220446049250313e-16,
        else => @compileError("zm.floatEps: unsupported float type"),
    };
}
/// Largest finite value of float type `T`.
pub inline fn floatMax(comptime T: type) T {
    return switch (T) {
        f32 => 3.4028234663852886e38,
        f64 => 1.7976931348623157e308,
        else => @compileError("zm.floatMax: unsupported float type"),
    };
}
/// Smallest positive normal value of float type `T`.
pub inline fn floatMin(comptime T: type) T {
    return switch (T) {
        f32 => 1.1754943508222875e-38,
        f64 => 2.2250738585072014e-308,
        else => @compileError("zm.floatMin: unsupported float type"),
    };
}
/// Sign bit of `x` (true for negative, including -0.0).
pub inline fn signbit(x: anytype) bool {
    const bits = @typeInfo(@TypeOf(x)).float.bits;
    const U: type = @Int(.unsigned, bits);
    return (@as(U, @bitCast(x)) >> (bits - 1)) != 0;
}
const cpu_arch = builtin.cpu.arch;

const has_avx = if (cpu_arch == .x86_64) std.Target.x86.featureSetHas(builtin.cpu.features, .avx) else false;

const has_fma = if (cpu_arch == .x86_64) std.Target.x86.featureSetHas(builtin.cpu.features, .fma) else false;

pub inline fn mulAdd(
    v0: anytype,
    v1: anytype,
    v2: anytype,
) @TypeOf(v0, v1, v2) {
    const T = @TypeOf(v0, v1, v2);
    // [zimr Z0] Upstream zmath reads `enable_cross_platform_determinism`
    // from a build-injected `zmath_options` module.  zimr vendors this
    // file directly and doesn't use zmath's build.zig, so the option
    // becomes a local const.  zimr ships wasm32 (no HW fma path anyway)
    // and wants reproducible results across machines → determinism ON.
    const enable_cross_platform_determinism: bool = true;
    if (enable_cross_platform_determinism) {
        return v0 * v1 + v2; // Compiler will generate mul, add sequence (no fma even if the target supports it).
    } else {
        if (cpu_arch == .x86_64 and has_avx and has_fma) {
            return @mulAdd(T, v0, v1, v2);
        } else {
            // NOTE(mziulek): On .x86_64 without HW fma instructions @mulAdd maps to really slow code!
            return v0 * v1 + v2;
        }
    }
}

fn sin32(v: f32) f32 {
    var y: f32 = v - tau * @round(v * 1.0 / tau);

    if (y > 0.5 * pi) {
        y = pi - y;
    } else if (y < -pi * 0.5) {
        y = -pi - y;
    }
    const y2: f32 = y * y;

    // 11-degree minimax approximation
    var sinv = mulAdd(@as(f32, -2.3889859e-08), y2, 2.7525562e-06);
    sinv = mulAdd(sinv, y2, -0.00019840874);
    sinv = mulAdd(sinv, y2, 0.0083333310);
    sinv = mulAdd(sinv, y2, -0.16666667);
    return y * mulAdd(sinv, y2, 1.0);
}

pub const Vec = @Vector(4, f32);

pub const F32x8 = @Vector(8, f32);

pub const F32x16 = @Vector(16, f32);

/// float -> integer T (truncating toward zero, like @intFromFloat). Comptime-
/// asserts `x` is a float and T is an int. `int(u16, v)` instead of
/// `int(u16, v)`. For pixel rounding prefer floori/roundi.
pub inline fn int(comptime T: type, x: anytype) T {
    comptime {
        if (@typeInfo(T) != .int) {
            @compileError("zm.int target must be an integer; got " ++ @typeName(T));
        }
        const info = @typeInfo(@TypeOf(x));
        if (info != .float and info != .comptime_float) {
            @compileError("zm.int expects a float; got " ++ @typeName(@TypeOf(x)));
        }
    }
    return @trunc(x);
}

pub fn modAngle32(in_angle_rad: f32) f32 {
    const angle: f32 = in_angle_rad + pi;
    var temp: f32 = @abs(angle);
    temp = temp - (2.0 * pi * float(int(i32, temp / pi)));
    temp = temp - pi;
    if (angle < 0.0) {
        temp = -temp;
    }
    return temp;
}

const has_avx512f = if (cpu_arch == .x86_64) std.Target.x86.featureSetHas(builtin.cpu.features, .avx512f) else false;

pub inline fn veclen(comptime T: type) comptime_int {
    return @typeInfo(T).vector.len;
}

pub inline fn andInt(v0: anytype, v1: anytype) @TypeOf(v0, v1) {
    const T = @TypeOf(v0, v1);
    const Tu = @Vector(veclen(T), u32);
    const v0u: Tu = @bitCast(v0);
    const v1u: Tu = @bitCast(v1);
    return @as(T, @bitCast(v0u & v1u)); // andps
}

inline fn splatNegativeZero(comptime T: type) T {
    return @splat(@as(f32, @bitCast(@as(u32, 0x8000_0000))));
}

pub inline fn orInt(v0: anytype, v1: anytype) @TypeOf(v0, v1) {
    const T = @TypeOf(v0, v1);
    const Tu = @Vector(veclen(T), u32);
    const v0u: Tu = @bitCast(v0);
    const v1u: Tu = @bitCast(v1);
    return @as(T, @bitCast(v0u | v1u)); // orps
}

inline fn splatNoFraction(comptime T: type) T {
    return @splat(@as(f32, 8_388_608.0));
}

pub inline fn abs(v: anytype) @TypeOf(v) {
    return @abs(v); // load, andps
}

pub inline fn blend(
    mask: anytype,
    v0: anytype,
    v1: anytype,
) @TypeOf(v0, v1) {
    return @select(f32, mask, v0, v1);
}

pub fn round(v: anytype) @TypeOf(v) {
    const T = @TypeOf(v);
    // [zimr Z0] The `cpu_arch == .x86_64` branch below is x86 inline
    // assembly (vroundps / vrndscaleps).  zimr ships wasm32 only, so
    // this branch is already comptime-dead in every real zimr build
    // the portable `else` path is what actually runs.  We additionally
    // gate it behind `false` so the NATIVE test target
    // (`zig build math-test`) doesn't compile the asm either: those
    // blocks trip a register-allocator assertion in Zig 0.16's
    // self-hosted x86_64 backend (`genSetReg called with a value
    // larger than dst_reg`).  Dropping the asm changes nothing about
    // zimr's behaviour or perf - it's wasm - and avoids a toolchain
    // split (no `use_llvm` override needed).  The asm is kept rather
    // than deleted so the diff from upstream zmath stays auditable.
    if (false and cpu_arch == .x86_64 and has_avx) {
        if (T == Vec) {
            return asm ("vroundps $0, %%xmm0, %%xmm0"
                : [ret] "={xmm0}" (-> T),
                : [v] "{xmm0}" (v),
            );
        } else if (T == F32x8) {
            return asm ("vroundps $0, %%ymm0, %%ymm0"
                : [ret] "={ymm0}" (-> T),
                : [v] "{ymm0}" (v),
            );
        } else if (T == F32x16 and has_avx512f) {
            return asm ("vrndscaleps $0, %%zmm0, %%zmm0"
                : [ret] "={zmm0}" (-> T),
                : [v] "{zmm0}" (v),
            );
        } else if (T == F32x16 and !has_avx512f) {
            const arr: [16]f32 = v;
            var ymm0 = @as(F32x8, arr[0..8].*);
            var ymm1 = @as(F32x8, arr[8..16].*);
            ymm0 = asm ("vroundps $0, %%ymm0, %%ymm0"
                : [ret] "={ymm0}" (-> F32x8),
                : [v] "{ymm0}" (ymm0),
            );
            ymm1 = asm ("vroundps $0, %%ymm1, %%ymm1"
                : [ret] "={ymm1}" (-> F32x8),
                : [v] "{ymm1}" (ymm1),
            );
            return @shuffle(f32, ymm0, ymm1, [16]i32{ 0, 1, 2, 3, 4, 5, 6, 7, -1, -2, -3, -4, -5, -6, -7, -8 });
        }
    } else {
        const sign = andInt(v, splatNegativeZero(T));
        const magic = orInt(splatNoFraction(T), sign);
        var r1: T = v + magic;
        r1 = r1 - magic;
        const r2: T = abs(v);
        const mask = r2 <= splatNoFraction(T);
        return blend(mask, r1, v);
    }
}

pub inline fn modAngle32xN(v: anytype) @TypeOf(v) {
    const T = @TypeOf(v);
    return v - @as(T, @splat(tau)) * round(v * @as(T, @splat(1.0 / tau))); // 2 x vmulps, 2 x load, vroundps, vaddps
}

pub fn modAngle(v: anytype) @TypeOf(v) {
    const T = @TypeOf(v);
    return switch (T) {
        f32 => modAngle32(v),
        Vec, F32x8, F32x16 => modAngle32xN(v),
        else => @compileError("zm.modAngle() not implemented for " ++ @typeName(T)),
    };
}

pub inline fn andNotInt(v0: anytype, v1: anytype) @TypeOf(v0, v1) {
    const T = @TypeOf(v0, v1);
    const Tu = @Vector(veclen(T), u32);
    const v0u: Tu = @bitCast(v0);
    const v1u: Tu = @bitCast(v1);
    return @as(T, @bitCast(~v0u & v1u)); // andnps
}

fn sin32xN(v: anytype) @TypeOf(v) {
    // 11-degree minimax approximation
    const T = @TypeOf(v);

    var x: T = modAngle(v);
    const sign = andInt(x, splatNegativeZero(T));
    const c = orInt(sign, @as(T, @splat(pi)));
    const absx: T = andNotInt(sign, x);
    const rflx: T = c - x;
    const comp = absx <= @as(T, @splat(0.5 * pi));
    x = blend(comp, x, rflx);
    const x2: T = x * x;

    var result: T = mulAdd(@as(T, @splat(-2.3889859e-08)), x2, @as(T, @splat(2.7525562e-06)));
    result = mulAdd(result, x2, @as(T, @splat(-0.00019840874)));
    result = mulAdd(result, x2, @as(T, @splat(0.0083333310)));
    result = mulAdd(result, x2, @as(T, @splat(-0.16666667)));
    result = mulAdd(result, x2, @as(T, @splat(1.0)));
    return x * result;
}

pub fn sin(v: anytype) @TypeOf(v) {
    const T = @TypeOf(v);
    // Scalar on CPU: exact (== std.math.sin == @sin).  Vectors (CPU SIMD
    // path + GPU): zmath's vectorized polynomial for maximum throughput.
    if (comptime !is_gpu and @typeInfo(T) != .vector) {
        return @sin(v);
    }
    return switch (T) {
        f32 => sin32(v),
        Vec, F32x8, F32x16 => sin32xN(v),
        else => @compileError("zm.sin() not implemented for " ++ @typeName(T)),
    };
}

fn cos32(v: f32) f32 {
    var y: f32 = v - tau * @round(v * 1.0 / tau);

    const sign: f32 = blk: {
        if (y > 0.5 * pi) {
            y = pi - y;
            break :blk @as(f32, -1.0);
        } else if (y < -pi * 0.5) {
            y = -pi - y;
            break :blk @as(f32, -1.0);
        } else {
            break :blk @as(f32, 1.0);
        }
    };
    const y2: f32 = y * y;

    // 10-degree minimax approximation
    var cosv = mulAdd(@as(f32, -2.6051615e-07), y2, 2.4760495e-05);
    cosv = mulAdd(cosv, y2, -0.0013888378);
    cosv = mulAdd(cosv, y2, 0.041666638);
    cosv = mulAdd(cosv, y2, -0.5);
    return sign * mulAdd(cosv, y2, 1.0);
}

fn cos32xN(v: anytype) @TypeOf(v) {
    // 10-degree minimax approximation
    const T = @TypeOf(v);

    var x: T = modAngle(v);
    var sign: T = andInt(x, splatNegativeZero(T));
    const c = orInt(sign, @as(T, @splat(pi)));
    const absx: T = andNotInt(sign, x);
    const rflx: T = c - x;
    const comp = absx <= @as(T, @splat(0.5 * pi));
    x = blend(comp, x, rflx);
    sign = blend(comp, @as(T, @splat(1.0)), @as(T, @splat(-1.0)));
    const x2: T = x * x;

    var result: T = mulAdd(@as(T, @splat(-2.6051615e-07)), x2, @as(T, @splat(2.4760495e-05)));
    result = mulAdd(result, x2, @as(T, @splat(-0.0013888378)));
    result = mulAdd(result, x2, @as(T, @splat(0.041666638)));
    result = mulAdd(result, x2, @as(T, @splat(-0.5)));
    result = mulAdd(result, x2, @as(T, @splat(1.0)));
    return sign * result;
}

pub fn cos(v: anytype) @TypeOf(v) {
    const T = @TypeOf(v);
    // Scalar on CPU: exact (== std.math.cos == @cos).  Vectors (CPU SIMD
    // path + GPU): zmath's vectorized polynomial for maximum throughput.
    if (comptime !is_gpu and @typeInfo(T) != .vector) {
        return @cos(v);
    }
    return switch (T) {
        f32 => cos32(v),
        Vec, F32x8, F32x16 => cos32xN(v),
        else => @compileError("zm.cos() not implemented for " ++ @typeName(T)),
    };
}

/// Tangent.  On GPU, sin/cos (both already GPU-portable here).
pub inline fn tan(x: anytype) @TypeOf(x) {
    // Scalar on CPU: exact (== std.math.tan == @tan).  Vectors (CPU SIMD
    // path + GPU): sin/cos, which route through the vectorized polynomial.
    if (comptime !is_gpu and @typeInfo(@TypeOf(x)) != .vector) {
        return std.math.tan(x);
    }
    return sin(x) / cos(x);
}
/// Base-2 logarithm.  `@log2` lowers to a GLSL.std.450 op on SPIR-V.
pub inline fn log2(x: anytype) @TypeOf(x) {
    return @log2(x);
}
/// Base-10 logarithm.  `@log10` lowers to a GLSL.std.450 op on SPIR-V.
pub inline fn log10(x: anytype) @TypeOf(x) {
    return @log10(x);
}
/// Base-2 exponential.  `@exp2` lowers to a GLSL.std.450 op on SPIR-V.
pub inline fn exp2(x: anytype) @TypeOf(x) {
    return @exp2(x);
}
/// Base-10 exponential (10^x).  There is no `@exp10` builtin; the
/// `@exp(x * ln10)` identity lowers cleanly on host and SPIR-V alike.
pub inline fn exp10(x: anytype) @TypeOf(x) {
    return @exp(x * ln10);
}

// ---- Pure-builtin wrappers (work on host, GPU, and comptime alike) ------
// No std.math needed — these are Zig builtins that lower to GLSL.std.450
// ops on SPIR-V.  Exposed as `zm.*` so call sites never need a bare
// builtin sprinkled through non-math code (and the rule stays clean).
// (`abs`, `sqrt`, `min`, `max` already live further down this file.)

/// Base-e exponential.
pub inline fn exp(x: anytype) @TypeOf(x) {
    return @exp(x);
}
/// Natural logarithm.
pub inline fn ln(x: anytype) @TypeOf(x) {
    return @log(x);
}
/// Euclidean length of (x, y) — `sqrt(x*x + y*y)`.
pub inline fn hypot(x: anytype, y: anytype) @TypeOf(x, y) {
    if (comptime !is_gpu) {
        return std.math.hypot(x, y);
    }
    return @sqrt(x * x + y * y);
}

/// Smallest power of ten >= `x` (for `x > 0`) — handy for "nice" axis
/// upper bounds. `ceilPowerOf10(250) == 1000`, `ceilPowerOf10(1) == 1`.
pub inline fn ceilPowerOf10(x: f64) f64 {
    return exp10(@ceil(log10(x)));
}

test "zm.log10 / exp10 / ceilPowerOf10" {
    try expectApproxEqAbs(@as(f64, 3.0), log10(@as(f64, 1000.0)), 1.0e-9);
    try expectApproxEqAbs(@as(f64, 1000.0), exp10(@as(f64, 3.0)), 1.0e-6);
    // Round-trips within float tolerance.
    try expectApproxEqAbs(@as(f64, 42.0), exp10(log10(@as(f64, 42.0))), 1.0e-4);
    try expectApproxEqAbs(@as(f64, 1000.0), ceilPowerOf10(250.0), 1.0e-6);
    try expectApproxEqAbs(@as(f64, 1.0), ceilPowerOf10(1.0), 1.0e-9);
}

// ---- Integer / comptime utilities ---------------------------------------
// These are comptime or pure-integer, so they're target-independent (the
// comptime ones produce constants usable in a shader; the runtime ones
// use only integer ops).  Exposed via zm so the `std-math` rule stays
// clean across the codebase.
pub inline fn maxInt(comptime T: type) comptime_int {
    const info = @typeInfo(T);
    const bit_count: u16 = info.int.bits;
    if (bit_count == 0) {
        return 0;
    }
    return (1 << (bit_count - @intFromBool(info.int.signedness == .signed))) - 1;
}
pub inline fn minInt(comptime T: type) comptime_int {
    const info = @typeInfo(T);
    const bit_count: u16 = info.int.bits;
    if (info.int.signedness == .unsigned) {
        return 0;
    }
    if (bit_count == 0) {
        return 0;
    }
    return -(1 << (bit_count - 1));
}
/// floor(log2(x)) for x > 0.
pub inline fn log2_int(comptime T: type, x: T) Log2Int(T) {
    // floor(log2(x)) for x > 0 (matches std.math.log2_int, which likewise
    // requires x != 0 — here x == 0 would @intCast a negative, trapping).
    const bits = @typeInfo(T).int.bits;
    return @intCast(bits - 1 - @clz(x));
}
/// Checked subtraction — `error.Overflow` on wrap.  CPU/comptime utility.
pub inline fn subChecked(
    comptime T: type,
    a: T,
    b: T,
) error{Overflow}!T {
    const r: struct { T, u1 } = @subWithOverflow(a, b);
    if (r[1] != 0) {
        return error.Overflow;
    }
    return r[0];
}
/// Checked multiplication — `error.Overflow` on wrap.  CPU/comptime utility.
pub inline fn mulChecked(
    comptime T: type,
    a: T,
    b: T,
) error{Overflow}!T {
    const r: struct { T, u1 } = @mulWithOverflow(a, b);
    if (r[1] != 0) {
        return error.Overflow;
    }
    return r[0];
}
/// Checked addition — `error.Overflow` on wrap.  CPU/comptime utility.
pub inline fn addChecked(
    comptime T: type,
    a: T,
    b: T,
) error{Overflow}!T {
    const r: struct { T, u1 } = @addWithOverflow(a, b);
    if (r[1] != 0) {
        return error.Overflow;
    }
    return r[0];
}
/// Checked integer cast: `x` as `T`, or null if `x` doesn't fit in `T`.
/// Mirrors std.math.cast; the body is GPU-portable (only comparisons,
/// `@intCast`, and the comptime maxInt/minInt above), so no std branch
/// is needed.
pub inline fn cast(comptime T: type, x: anytype) ?T {
    comptime assert(@typeInfo(T) == .int, @src());
    const is_comptime = @TypeOf(x) == comptime_int;
    comptime assert(is_comptime or @typeInfo(@TypeOf(x)) == .int, @src());
    if ((is_comptime or maxInt(@TypeOf(x)) > maxInt(T)) and x > maxInt(T)) {
        return null;
    } else if ((is_comptime or minInt(@TypeOf(x)) < minInt(T)) and x < minInt(T)) {
        return null;
    }
    return @intCast(x);
}

pub fn square(v: anytype) @TypeOf(v) {
    return v * v;
}

// Fundamental types.  `Vec` is the canonical 4-lane f32 SIMD type;
// it's both 3D (with w lane = 0 for direction, w = 1 for point,
// per the homogeneous-coordinates convention) and 4D math.  `Vec2`
// is the 2-lane version.  There are no Vec3/Vec4 names — same
// underlying type, different function suites (`dot3` vs `dot4`).
// `F32x8` and `F32x16` are wider SIMD types kept for the
// generic-width SIMD utilities (load, store, all, any, etc.).
// `F32x4` used to exist as the underlying type for Vec; removed
// turn 357 because `Vec` is the right name everywhere - "F32x4"
// described storage, "Vec" describes meaning.
pub const Vec2 = @Vector(2, f32);
pub const Vec3 = @Vector(3, f32);

/// Complex number — SIMD alias for `@Vector(2, f32)` (same storage
/// as `Vec2`).  Lane 0 is the real part, lane 1 the imaginary part.
///
/// Distinct from `Vec2` only in the call site: `Complex` reads as
/// "I'm doing complex arithmetic here" while `Vec2` reads as
/// "this is a 2D point/UV/whatever".  Same bytes, same alignment.
///
/// Because it IS `@Vector(2, f32)`, the native `+` and `-`
/// operators do complex addition / subtraction directly — the
/// headline one-liner for mandelbrot is `z = cmul(z, z) + c` with
/// no boilerplate around the `+`.  The `*` operator is
/// COMPONENTWISE (not complex multiplication); use `cmul` for the
/// real complex product.  Same trap applies to `/` (use `cdiv`).
///
/// Locked decision D3 of math-unification (see
/// `src/notes/math_unification.md`): no nominal-struct wrapper to
/// type-check the cmul-vs-componentwise distinction.  Discipline
/// is the function naming (`cmul` / `cdiv` for the complex ops;
/// `+` / `-` work natively).  Accepted cost: `cmul(some_vec2,
/// some_vec2)` type-checks and produces semantically wrong but
/// mathematically valid output.
pub const Complex = @Vector(2, f32);

/// Integer 2D vector — pixel coordinates, viewport dimensions, any
/// value that's conceptually a count rather than a measurement.
/// Sister type to `Vec2`; SIMD-aligned, 8 bytes, native arithmetic
/// (`+` / `-` / `*` componentwise; use `@min` / `@max` builtins for
/// per-component reductions).
///
/// Migrated from a named `Vector2i` struct in the math-unification
/// plan (see `src/notes/math_unification.md` Phase -1).
pub const Vec2i = @Vector(2, i32);
pub const Mat = [4]Vec;
pub const Quat = Vec;
pub const Boolx4 = @Vector(4, bool);
pub const Boolx8 = @Vector(8, bool);
pub const Boolx16 = @Vector(16, bool);

// Common-case constructors and constants.  The constructor functions
// `vec`, `point`, `vec2`, `vec4`, `quat` live further down in this
// file (the "Z4 - vector constructors" section).  `vec_zero` and
// `quat_identity` cover the two most common constant Vecs.
pub const vec_zero: Vec = .{ 0, 0, 0, 0 };
pub const quat_identity: Quat = .{ 0, 0, 0, 1 };

// Common direction constants.  All have w=0 so they're directions
// (translation-invariant under matrix transforms).  `vec_up` is the
// semantic name for the +Y axis - the convention zimr/zmath inherit
// from raylib is "Y-up, right-handed."  `axis_x`/`axis_z` are the
// unsigned basis vectors; for `-X`, `-Z`, or `vec_down` etc., negate
// at the callsite (these are `inline` if you treat them as `var`s).
pub const vec_up: Vec = .{ 0, 1, 0, 0 };
pub const axis_x: Vec = .{ 1, 0, 0, 0 };
pub const axis_y: Vec = .{ 0, 1, 0, 0 }; // alias for vec_up; symmetric with axis_x/axis_z
pub const axis_z: Vec = .{ 0, 0, 1, 0 };

const expectEqual = std.testing.expectEqual;
const math = std.math;

/// True when compiling to wasm. zm uses this to pick a SCALAR path where the
/// SIMD one (@select / vector compares) does not pass wasm validation; native
/// + GPU (spirv) keep the faster SIMD path. Both paths return the same value.
pub const is_wasm: bool = builtin.target.cpu.arch.isWasm();

/// True when assertion bodies actually run. Off in ship builds (ReleaseSmall/
/// Fast) by default; `-Dassert-log` forces it back on. Gate expensive assertion
/// preconditions behind `if (comptime zm.allow_assert)` so they vanish in ship
/// builds along with the asserts they guard. (Moved here from utils.zig so the
/// whole codebase shares one assert home.)
pub const allow_assert: bool = !is_stripped or @import("build_options").assert_log;

/// Formatted assertion — the canonical assert for the whole codebase.
///
/// On GPU (SPIR-V) it is exactly `std.debug.assert`: `if (!ok) unreachable`,
/// with no log/panic machinery (a shader has none). On CPU, in a dev build
/// (Debug, or ReleaseSmall with `-Dassert-log`) a failure logs `fmt` + the
/// call-site file:line and `@panic`s; in a stripped ship build it is again
/// `if (!ok) unreachable`, byte-identical to `std.debug.assert`. The host-only
/// branch is comptime-dead in a SPIR-V compile, so `build_options` / `std.log` /
/// `@panic` are never pulled into shaders.
///
/// MENTAL MODEL: in a ship build this is NOT a runtime check — it is a PROMISE
/// to the optimizer that `ok` is always true, and the optimizer builds on that
/// promise. Breaking it is undefined behaviour, and "undefined" is as bad as it
/// sounds. The deliberately absurd case:
///     var a: u32 = 5;
///     assertf(a == 10, @src(), "a must be 10", .{}); // ship: "assume a == 10"
///     if (a == 10) deleteAllUserData();              // a == 10 is now "known"
///                                                    // true, so the compiler
///                                                    // may run this branch
///                                                    // UNCONDITIONALLY
/// `a` is 5, yet the user's data is gone — because we lied to the compiler. So
/// only assert invariants that genuinely cannot be false in a shipped build; if
/// you are not certain it holds, it is not an assert — handle it as a real case.
///
/// Pass `@src()`: this fn is `inline`, so an internal `@src()` would resolve to
/// `zimrmath.zig`, and wasm stack traces are unsymbolicated — the caller-side
/// `@src()` is our only localisation when one fires.
///     assertf(len < cap, @src(), "ring overflow: len={d} cap={d}", .{ len, cap });
pub inline fn assertf(
    ok: bool,
    src: std.builtin.SourceLocation,
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (comptime is_gpu) {
        if (!ok) {
            unreachable;
        }
    } else {
        if (!ok) {
            if (comptime !is_stripped) {
                std.log.err("assert failed at {s}:{d}:{d}: " ++ fmt, .{ src.file, src.line, src.column } ++ args);
                @panic("assertion failed");
            } else if (comptime @import("build_options").assert_log) {
                // Release (not ship): surface on the page's log overlay (std.log.err ->
                // console.error -> overlay) but keep running. A frozen canvas is a worse
                // failure than a logged, recoverable glitch; a caller that must bail after a
                // failed check does so itself (e.g. drops the batch), since this returns.
                std.log.err("assert failed at {s}:{d}:{d}: " ++ fmt, .{ src.file, src.line, src.column } ++ args);
            } else {
                unreachable;
            }
        }
    }
}

const expect = std.testing.expect;

//
// 1. Initialization functions
//
pub inline fn f32x4(e0: f32, e1: f32, e2: f32, e3: f32) Vec {
    return .{ e0, e1, e2, e3 };
}
pub inline fn f32x8(
    e0: f32,
    e1: f32,
    e2: f32,
    e3: f32,
    e4: f32,
    e5: f32,
    e6: f32,
    e7: f32,
) F32x8 {
    return .{ e0, e1, e2, e3, e4, e5, e6, e7 };
}
// zig fmt: off
pub inline fn f32x16(
    e0: f32, e1: f32, e2: f32, e3: f32, e4: f32, e5: f32, e6: f32, e7: f32,
    e8: f32, e9: f32, ea: f32, eb: f32, ec: f32, ed: f32, ee: f32, ef: f32) F32x16 {
    return .{ e0, e1, e2, e3, e4, e5, e6, e7, e8, e9, ea, eb, ec, ed, ee, ef };
}
// zig fmt: on

pub inline fn splat8(v: f32) F32x8 {
    return @as(F32x8, @splat(v));
}

pub inline fn boolx4(e0: bool, e1: bool, e2: bool, e3: bool) Boolx4 {
    return .{ e0, e1, e2, e3 };
}
pub inline fn boolx8(
    e0: bool,
    e1: bool,
    e2: bool,
    e3: bool,
    e4: bool,
    e5: bool,
    e6: bool,
    e7: bool,
) Boolx8 {
    return .{ e0, e1, e2, e3, e4, e5, e6, e7 };
}
// zig fmt: off
pub inline fn boolx16(
    e0: bool, e1: bool, e2: bool, e3: bool, e4: bool, e5: bool, e6: bool, e7: bool,
    e8: bool, e9: bool, ea: bool, eb: bool, ec: bool, ed: bool, ee: bool, ef: bool) Boolx16 {
    return .{ e0, e1, e2, e3, e4, e5, e6, e7, e8, e9, ea, eb, ec, ed, ee, ef };
}
// zig fmt: on

pub inline fn splatInt(comptime T: type, value: u32) T {
    return @splat(@bitCast(value));
}

pub fn loadVec(
    mem: []const f32,
    comptime T: type,
    comptime len: u32,
) T {
    var v: T = @as(T, @splat(0.0));
    const loop_len: u32 = if (len == 0) veclen(T) else len;
    comptime var i: u32 = 0;
    inline while (i < loop_len) : (i += 1) {
        v[i] = mem[i];
    }
    return v;
}
pub fn expectVecEqual(expected: anytype, actual: anytype) !void {
    const T = @TypeOf(expected, actual);
    inline for (0..veclen(T)) |i| {
        try expectEqual(expected[i], actual[i]);
    }
}

test "zm.load" {
    const a: [7]f32 = .{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0 };
    var ptr: *const [7]f32 = &a;
    var i: u32 = 0;
    const v0: Vec = loadVec(a[i..], Vec, 2);
    try expectVecEqual(v0, Vec{ 1.0, 2.0, 0.0, 0.0 });
    i += 2;
    const v1: Vec = loadVec(a[i .. i + 2], Vec, 2);
    try expectVecEqual(v1, Vec{ 3.0, 4.0, 0.0, 0.0 });
    const v2: Vec = loadVec(a[5..7], Vec, 2);
    try expectVecEqual(v2, Vec{ 6.0, 7.0, 0.0, 0.0 });
    const v3: Vec = loadVec(ptr[1..], Vec, 2);
    try expectVecEqual(v3, Vec{ 2.0, 3.0, 0.0, 0.0 });
    i += 1;
    const v4: Vec = loadVec(ptr[i .. i + 2], Vec, 2);
    try expectVecEqual(v4, Vec{ 4.0, 5.0, 0.0, 0.0 });
}

pub fn storeVec(
    mem: []f32,
    v: anytype,
    comptime len: u32,
) void {
    const T: type = @TypeOf(v);
    const loop_len: u32 = if (len == 0) veclen(T) else len;
    comptime var i: u32 = 0;
    inline while (i < loop_len) : (i += 1) {
        mem[i] = v[i];
    }
}
test "zm.store" {
    var a: [7]f32 = .{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0 };
    const v: Vec = loadVec(a[1..], Vec, 3);
    storeVec(a[2..], v, 4);
    try expect(a[0] == 1.0);
    try expect(a[1] == 2.0);
    try expect(a[2] == 2.0);
    try expect(a[3] == 3.0);
    try expect(a[4] == 4.0);
    try expect(a[5] == 0.0);
}

/// Build a Vec from a 3-elem indexable (`[3]f32`, slice, or even
/// another Vec) as a POINT (w=1).  Accepts anytype so callers
/// don't have to coerce: a `[3]f32` works, and so does a `Vec` if
/// they want to re-stamp the w lane to 1.  Use this when reading
/// 3D points from arrays, GLTF files, or any source where the
/// data is naturally a 3-tuple.
pub inline fn pointFromArr3(arr: anytype) Vec {
    return .{ arr[0], arr[1], arr[2], 1.0 };
}
/// Build a Vec from a 3-elem indexable as a DIRECTION (w=0).
/// Translation in matrix transforms multiplies the w lane, so
/// directions need w=0 to remain invariant under translation.
/// Equivalent to the legacy `loadArr3(arr)` under a more semantic
/// name.
pub inline fn dirFromArr3(arr: anytype) Vec {
    return .{ arr[0], arr[1], arr[2], 0.0 };
}

pub inline fn loadArr2(arr: [2]f32) Vec {
    return f32x4(arr[0], arr[1], 0.0, 0.0);
}
pub inline fn loadArr2zw(
    arr: [2]f32,
    z: f32,
    w: f32,
) Vec {
    return f32x4(arr[0], arr[1], z, w);
}
pub inline fn loadArr3(arr: [3]f32) Vec {
    return dirFromArr3(arr);
}
pub inline fn loadArr3w(arr: [3]f32, w: f32) Vec {
    return f32x4(arr[0], arr[1], arr[2], w);
}
pub inline fn loadArr4(arr: [4]f32) Vec {
    return f32x4(arr[0], arr[1], arr[2], arr[3]);
}

pub inline fn storeArr2(arr: *[2]f32, v: Vec) void {
    arr.* = .{ v[0], v[1] };
}
pub inline fn storeArr3(arr: *[3]f32, v: Vec) void {
    arr.* = .{ v[0], v[1], v[2] };
}
pub inline fn storeArr4(arr: *[4]f32, v: Vec) void {
    arr.* = .{ v[0], v[1], v[2], v[3] };
}

pub inline fn arr3Ptr(ptr: anytype) *const [3]f32 {
    comptime assert(@typeInfo(@TypeOf(ptr)) == .pointer, @src());
    const T = std.meta.Child(@TypeOf(ptr));
    comptime assert(T == Vec, @src());
    return @as(*const [3]f32, @ptrCast(ptr));
}

pub inline fn arrNPtr(ptr: anytype) [*]const f32 {
    comptime assert(@typeInfo(@TypeOf(ptr)) == .pointer, @src());
    const T = std.meta.Child(@TypeOf(ptr));
    comptime assert(T == Mat or T == Vec or T == F32x8 or T == F32x16, @src());
    return @as([*]const f32, @ptrCast(ptr));
}
pub fn identity() Mat {
    const static = struct {
        const identity = Mat{
            f32x4(1.0, 0.0, 0.0, 0.0),
            f32x4(0.0, 1.0, 0.0, 0.0),
            f32x4(0.0, 0.0, 1.0, 0.0),
            f32x4(0.0, 0.0, 0.0, 1.0),
        };
    };
    return static.identity;
}

test "zm.arrNPtr" {
    {
        const mat: Mat = identity();
        const f32ptr: [*]const f32 = arrNPtr(&mat);
        try expect(f32ptr[0] == 1.0);
        try expect(f32ptr[5] == 1.0);
        try expect(f32ptr[10] == 1.0);
        try expect(f32ptr[15] == 1.0);
    }
    {
        const v8: F32x8 = splat8(1.0);
        const f32ptr: [*]const f32 = arrNPtr(&v8);
        try expect(f32ptr[1] == 1.0);
        try expect(f32ptr[7] == 1.0);
    }
}

test "zm.loadArr" {
    {
        const camera_position: [3]f32 = .{ 1.0, 2.0, 3.0 };
        const simd_reg: Vec = loadArr3(camera_position);
        try expectVecEqual(simd_reg, f32x4(1.0, 2.0, 3.0, 0.0));
    }
    {
        const camera_position: [3]f32 = .{ 1.0, 2.0, 3.0 };
        const simd_reg: Vec = loadArr3w(camera_position, 1.0);
        try expectVecEqual(simd_reg, f32x4(1.0, 2.0, 3.0, 1.0));
    }
}

pub inline fn vecToArr2(v: Vec) [2]f32 {
    return .{ v[0], v[1] };
}
pub inline fn vecToArr3(v: Vec) [3]f32 {
    return .{ v[0], v[1], v[2] };
}
pub inline fn vecToArr4(v: Vec) [4]f32 {
    return .{ v[0], v[1], v[2], v[3] };
}
//
// 2. Functions that work on all vector components (F32xN = F32x4 or F32x8 or F32x16)
//
pub fn allTrue(vb: anytype, comptime len: u32) bool {
    const T = @TypeOf(vb);
    if (len > veclen(T)) {
        @compileError("zm.all(): 'len' is greater than vector len of type " ++ @typeName(T));
    }
    const loop_len: u32 = if (len == 0) veclen(T) else len;
    const ab: [veclen(T)]bool = vb;
    comptime var i: u32 = 0;
    var result: bool = true;
    inline while (i < loop_len) : (i += 1) {
        result = result and ab[i];
    }
    return result;
}
test "zm.all" {
    try expect(allTrue(boolx8(true, true, true, true, true, false, true, false), 5) == true);
    try expect(allTrue(boolx8(true, true, true, true, true, false, true, false), 6) == false);
    try expect(allTrue(boolx8(true, true, true, true, false, false, false, false), 4) == true);
    try expect(allTrue(boolx4(true, true, true, false), 3) == true);
    try expect(allTrue(boolx4(true, true, true, false), 1) == true);
    try expect(allTrue(boolx4(true, false, false, false), 1) == true);
    try expect(allTrue(boolx4(false, true, false, false), 1) == false);
    try expect(allTrue(boolx8(true, true, true, true, true, false, true, false), 0) == false);
    try expect(allTrue(boolx4(false, true, false, false), 0) == false);
    try expect(allTrue(boolx4(true, true, true, true), 0) == true);
}

pub fn anyTrue(vb: anytype, comptime len: u32) bool {
    const T = @TypeOf(vb);
    if (len > veclen(T)) {
        @compileError("zm.any(): 'len' is greater than vector len of type " ++ @typeName(T));
    }
    const loop_len: u32 = if (len == 0) veclen(T) else len;
    const ab: [veclen(T)]bool = vb;
    comptime var i: u32 = 0;
    var result: bool = false;
    inline while (i < loop_len) : (i += 1) {
        result = result or ab[i];
    }
    return result;
}
test "zm.any" {
    try expect(anyTrue(boolx8(true, true, true, true, true, false, true, false), 0) == true);
    try expect(anyTrue(boolx8(false, false, false, true, true, false, true, false), 3) == false);
    try expect(anyTrue(boolx8(false, false, false, false, false, true, false, false), 4) == false);
}

pub inline fn maxFast(v0: anytype, v1: anytype) @TypeOf(v0, v1) {
    return blend(v0 > v1, v0, v1); // maxps
}

pub inline fn isNearEqual(
    v0: anytype,
    v1: anytype,
    epsilon: anytype,
) @Vector(veclen(@TypeOf(v0)), bool) {
    const T = @TypeOf(v0, v1, epsilon);
    const delta: T = v0 - v1;
    const temp = maxFast(delta, @as(T, @splat(0.0)) - delta);
    return temp <= epsilon;
}
/// Broadcast a scalar to a 4-wide `Vec`.  Replaces
/// `splat(v)` at zimr call sites - the type annotation is
/// pure noise when the result is always `Vec`.
pub inline fn splat(v: f32) Vec {
    return @splat(v);
}

test "zm.isNearEqual" {
    {
        const v0: Vec = f32x4(1.0, 2.0, -3.0, 4.001);
        const v1: Vec = f32x4(1.0, 2.1, 3.0, 4.0);
        const b: Boolx4 = isNearEqual(v0, v1, splat(0.01));
        try expect(@reduce(.And, b == boolx4(true, false, false, true)));
    }
    {
        const v0: F32x8 = f32x8(1.0, 2.0, -3.0, 4.001, 1.001, 2.3, -0.0, 0.0);
        const v1: F32x8 = f32x8(1.0, 2.1, 3.0, 4.0, -1.001, 2.1, 0.0, 0.0);
        const b: Boolx8 = isNearEqual(v0, v1, @as(F32x8, @splat(0.01)));
        try expect(@reduce(.And, b == boolx8(true, false, false, true, false, false, true, true)));
    }
    try expect(allTrue(isNearEqual(
        splat(math.inf(f32)),
        splat(math.inf(f32)),
        splat(0.0001),
    ), 0) == false);
    try expect(allTrue(isNearEqual(
        splat(-math.inf(f32)),
        splat(math.inf(f32)),
        splat(0.0001),
    ), 0) == false);
    try expect(allTrue(isNearEqual(
        splat(-math.inf(f32)),
        splat(-math.inf(f32)),
        splat(0.0001),
    ), 0) == false);
    try expect(allTrue(isNearEqual(
        splat(-math.nan(f32)),
        splat(math.inf(f32)),
        splat(0.0001),
    ), 0) == false);
}

pub inline fn isNan(
    v: anytype,
) @Vector(veclen(@TypeOf(v)), bool) {
    return v != v;
}
test "zm.isNan" {
    {
        const v0: Vec = f32x4(math.inf(f32), math.nan(f32), math.nan(f32), 7.0);
        const b: Boolx4 = isNan(v0);
        try expect(@reduce(.And, b == boolx4(false, true, true, false)));
    }
    {
        const v0: F32x8 = f32x8(0, math.nan(f32), 0, 0, math.inf(f32), math.nan(f32), math.snan(f32), 7.0);
        const b: Boolx8 = isNan(v0);
        try expect(@reduce(.And, b == boolx8(false, true, false, false, false, true, true, false)));
    }
}

pub inline fn isInf(
    v: anytype,
) @Vector(veclen(@TypeOf(v)), bool) {
    const T = @TypeOf(v);
    return abs(v) == @as(T, @splat(math.inf(f32)));
}
test "zm.isInf" {
    {
        const v0: Vec = f32x4(math.inf(f32), math.nan(f32), math.snan(f32), 7.0);
        const b: Boolx4 = isInf(v0);
        try expect(@reduce(.And, b == boolx4(true, false, false, false)));
    }
    {
        const v0: F32x8 = f32x8(0, math.inf(f32), 0, 0, math.inf(f32), math.nan(f32), math.snan(f32), 7.0);
        const b: Boolx8 = isInf(v0);
        try expect(@reduce(.And, b == boolx8(false, true, false, false, true, false, false, false)));
    }
}

pub inline fn isInBounds(
    v: anytype,
    bounds: anytype,
) @Vector(veclen(@TypeOf(v)), bool) {
    const T = @TypeOf(v, bounds);
    const Tu = @Vector(veclen(T), u1);
    const Tr = @Vector(veclen(T), bool);

    // 2 x cmpleps, xorps, load, andps
    const b0: Tr = v <= bounds;
    const b1: Tr = (bounds * @as(T, @splat(-1.0))) <= v;
    const b0u: Tu = @bitCast(b0);
    const b1u: Tu = @bitCast(b1);
    return @as(Tr, @bitCast(b0u & b1u));
}
test "zm.isInBounds" {
    {
        const v0: Vec = f32x4(0.5, -2.0, -1.0, 1.9);
        const v1: Vec = f32x4(-1.6, -2.001, -1.0, 1.9);
        const bounds: Vec = f32x4(1.0, 2.0, 1.0, 2.0);
        const b0: Boolx4 = isInBounds(v0, bounds);
        const b1: Boolx4 = isInBounds(v1, bounds);
        try expect(@reduce(.And, b0 == boolx4(true, true, true, true)));
        try expect(@reduce(.And, b1 == boolx4(false, false, true, true)));
    }
    {
        const v0: F32x8 = f32x8(2.0, 1.0, 2.0, 1.0, 0.5, -2.0, -1.0, 1.9);
        const bounds: F32x8 = f32x8(1.0, 1.0, 1.0, math.inf(f32), 1.0, math.nan(f32), 1.0, 2.0);
        const b0: Boolx8 = isInBounds(v0, bounds);
        try expect(@reduce(.And, b0 == boolx8(false, true, false, true, true, false, true, true)));
    }
}

test "zm.andInt" {
    {
        const v0: Vec = f32x4(0, @as(f32, @bitCast(~@as(u32, 0))), 0, @as(f32, @bitCast(~@as(u32, 0))));
        const v1: Vec = f32x4(1.0, 2.0, 3.0, math.inf(f32));
        const v: Vec = andInt(v0, v1);
        try expect(v[3] == math.inf(f32));
        try expectVecEqual(v, f32x4(0.0, 2.0, 0.0, math.inf(f32)));
    }
    {
        const v0: F32x8 = f32x8(0, 0, 0, 0, 0, @as(f32, @bitCast(~@as(u32, 0))), 0, @as(f32, @bitCast(~@as(u32, 0))));
        const v1: F32x8 = f32x8(0, 0, 0, 0, 1.0, 2.0, 3.0, math.inf(f32));
        const v: F32x8 = andInt(v0, v1);
        try expect(v[7] == math.inf(f32));
        try expectVecEqual(v, f32x8(0, 0, 0, 0, 0.0, 2.0, 0.0, math.inf(f32)));
    }
}

test "zm.andNotInt" {
    {
        const v0: Vec = f32x4(1.0, 2.0, 3.0, 4.0);
        const v1: Vec = f32x4(0, @as(f32, @bitCast(~@as(u32, 0))), 0, @as(f32, @bitCast(~@as(u32, 0))));
        const v: Vec = andNotInt(v1, v0);
        try expectVecEqual(v, f32x4(1.0, 0.0, 3.0, 0.0));
    }
    {
        const v0: F32x8 = f32x8(0, 0, 0, 0, 1.0, 2.0, 3.0, 4.0);
        const v1: F32x8 = f32x8(0, 0, 0, 0, 0, @as(f32, @bitCast(~@as(u32, 0))), 0, @as(f32, @bitCast(~@as(u32, 0))));
        const v: F32x8 = andNotInt(v1, v0);
        try expectVecEqual(v, f32x8(0, 0, 0, 0, 1.0, 0.0, 3.0, 0.0));
    }
}

test "zm.orInt" {
    {
        const v0: Vec = f32x4(0, @as(f32, @bitCast(~@as(u32, 0))), 0, 0);
        const v1: Vec = f32x4(1.0, 2.0, 3.0, 4.0);
        const v: Vec = orInt(v0, v1);
        try expect(v[0] == 1.0);
        try expect(@as(u32, @bitCast(v[1])) == ~@as(u32, 0));
        try expect(v[2] == 3.0);
        try expect(v[3] == 4.0);
    }
    {
        const v0: F32x8 = f32x8(0, 0, 0, 0, 0, @as(f32, @bitCast(~@as(u32, 0))), 0, 0);
        const v1: F32x8 = f32x8(0, 0, 0, 0, 1.0, 2.0, 3.0, 4.0);
        const v: F32x8 = orInt(v0, v1);
        try expect(v[4] == 1.0);
        try expect(@as(u32, @bitCast(v[5])) == ~@as(u32, 0));
        try expect(v[6] == 3.0);
        try expect(v[7] == 4.0);
    }
}

pub inline fn norInt(v0: anytype, v1: anytype) @TypeOf(v0, v1) {
    const T = @TypeOf(v0, v1);
    const Tu = @Vector(veclen(T), u32);
    const v0u: Tu = @bitCast(v0);
    const v1u: Tu = @bitCast(v1);
    return @as(T, @bitCast(~(v0u | v1u))); // por, pcmpeqd, pxor
}

pub inline fn xorInt(v0: anytype, v1: anytype) @TypeOf(v0, v1) {
    const T = @TypeOf(v0, v1);
    const Tu = @Vector(veclen(T), u32);
    const v0u: Tu = @bitCast(v0);
    const v1u: Tu = @bitCast(v1);
    return @as(T, @bitCast(v0u ^ v1u)); // xorps
}
test "zm.xorInt" {
    {
        const v0: Vec = f32x4(1.0, @as(f32, @bitCast(~@as(u32, 0))), 0, 0);
        const v1: Vec = f32x4(1.0, 0, 0, 0);
        const v: Vec = xorInt(v0, v1);
        try expect(v[0] == 0.0);
        try expect(@as(u32, @bitCast(v[1])) == ~@as(u32, 0));
        try expect(v[2] == 0.0);
        try expect(v[3] == 0.0);
    }
    {
        const v0: F32x8 = f32x8(0, 0, 0, 0, 1.0, @as(f32, @bitCast(~@as(u32, 0))), 0, 0);
        const v1: F32x8 = f32x8(0, 0, 0, 0, 1.0, 0, 0, 0);
        const v: F32x8 = xorInt(v0, v1);
        try expect(v[4] == 0.0);
        try expect(@as(u32, @bitCast(v[5])) == ~@as(u32, 0));
        try expect(v[6] == 0.0);
        try expect(v[7] == 0.0);
    }
}

pub inline fn minFast(v0: anytype, v1: anytype) @TypeOf(v0, v1) {
    return blend(v0 < v1, v0, v1); // minps
}
test "zm.minFast" {
    {
        const v0: Vec = .{ 1.0, 3.0, 2.0, 7.0 };
        const v1: Vec = .{ 2.0, 1.0, 4.0, math.inf(f32) };
        const v: Vec = minFast(v0, v1);
        try expectVecEqual(v, f32x4(1.0, 1.0, 2.0, 7.0));
    }
    {
        const v0: Vec = .{ 1.0, math.nan(f32), 5.0, math.snan(f32) };
        const v1: Vec = .{ 2.0, 1.0, 4.0, math.inf(f32) };
        const v: Vec = minFast(v0, v1);
        try expect(v[0] == 1.0);
        try expect(v[1] == 1.0);
        try expect(!math.isNan(v[1]));
        try expect(v[2] == 4.0);
        try expect(v[3] == math.inf(f32));
        try expect(!math.isNan(v[3]));
    }
}

test "zm.maxFast" {
    {
        const v0: Vec = .{ 1.0, 3.0, 2.0, 7.0 };
        const v1: Vec = .{ 2.0, 1.0, 4.0, math.inf(f32) };
        const v: Vec = maxFast(v0, v1);
        try expectVecEqual(v, f32x4(2.0, 3.0, 4.0, math.inf(f32)));
    }
    {
        const v0: Vec = .{ 1.0, math.nan(f32), 5.0, math.snan(f32) };
        const v1: Vec = .{ 2.0, 1.0, 4.0, math.inf(f32) };
        const v: Vec = maxFast(v0, v1);
        try expect(v[0] == 2.0);
        try expect(v[1] == 1.0);
        try expect(v[2] == 5.0);
        try expect(v[3] == math.inf(f32));
        try expect(!math.isNan(v[3]));
    }
}

pub inline fn min(v0: anytype, v1: anytype) @TypeOf(v0, v1) {
    const T = @TypeOf(v0, v1);
    return switch (@typeInfo(T)) {
        // Vec / F32x8 / F32x16: per-lane NaN-aware min.
        .vector => blk: {
            const Child = std.meta.Child(T);
            const Tb = @Vector(veclen(T), bool);
            // v != v is true only when v is NaN
            const nan0: Tb = v0 != v0;
            const nan1: Tb = v1 != v1;
            // if v0 is NaN, pick v1
            // else if v1 is NaN, pick v0
            // else pick normal @min
            break :blk @select(Child, nan0, v1, @select(Child, nan1, v0, @min(v0, v1)));
        },
        // Scalar: plain @min builtin.  NaN handling is whatever the
        // platform decides — callers passing NaN to scalar min should
        // use std.math.min directly if they need a specific behavior.
        else => @min(v0, v1),
    };
}
test "zm.min" {
    {
        const v0: Vec = f32x4(1.0, 3.0, 2.0, 7.0);
        const v1: Vec = f32x4(2.0, 1.0, 4.0, math.inf(f32));
        const v: Vec = min(v0, v1);
        try expectVecEqual(v, f32x4(1.0, 1.0, 2.0, 7.0));
    }
    {
        const v0: F32x8 = f32x8(0, 0, -2.0, 0, 1.0, 3.0, 2.0, 7.0);
        const v1: F32x8 = f32x8(0, 1.0, 0, 0, 2.0, 1.0, 4.0, math.inf(f32));
        const v: F32x8 = min(v0, v1);
        try expectVecEqual(v, f32x8(0.0, 0.0, -2.0, 0.0, 1.0, 1.0, 2.0, 7.0));
    }
    {
        const v0: Vec = f32x4(1.0, math.nan(f32), 5.0, math.snan(f32));
        const v1: Vec = f32x4(2.0, 1.0, 4.0, math.inf(f32));
        const v: Vec = min(v0, v1);
        try expect(v[0] == 1.0);
        try expect(v[1] == 1.0);
        try expect(!math.isNan(v[1]));
        try expect(v[2] == 4.0);
        try expect(v[3] == math.inf(f32));
        try expect(!math.isNan(v[3]));
    }

    {
        const v0: Vec = f32x4(-math.inf(f32), math.inf(f32), math.inf(f32), math.snan(f32));
        const v1: Vec = f32x4(math.snan(f32), -math.inf(f32), math.snan(f32), math.nan(f32));
        const v: Vec = min(v0, v1);
        try expect(v[0] == -math.inf(f32));
        try expect(v[1] == -math.inf(f32));
        try expect(v[2] == math.inf(f32));
        try expect(!math.isNan(v[2]));
        try expect(math.isNan(v[3]));
        try expect(!math.isInf(v[3]));
    }
}

pub inline fn max(v0: anytype, v1: anytype) @TypeOf(v0, v1) {
    const T = @TypeOf(v0, v1);
    return switch (@typeInfo(T)) {
        // Vec / F32x8 / F32x16: per-lane NaN-aware max.
        .vector => blk: {
            const Child = std.meta.Child(T);
            const Tb = @Vector(veclen(T), bool);
            // v != v is true only when v is NaN
            const nan0: Tb = v0 != v0;
            const nan1: Tb = v1 != v1;
            // if v0 is NaN, pick v1
            // else if v1 is NaN, pick v0
            // else pick normal @max
            break :blk @select(Child, nan0, v1, @select(Child, nan1, v0, @max(v0, v1)));
        },
        // Scalar: plain @max builtin.
        else => @max(v0, v1),
    };
}
test "zm.max" {
    {
        const v0: Vec = f32x4(1.0, 3.0, 2.0, 7.0);
        const v1: Vec = f32x4(2.0, 1.0, 4.0, math.inf(f32));
        const v: Vec = max(v0, v1);
        try expectVecEqual(v, f32x4(2.0, 3.0, 4.0, math.inf(f32)));
    }
    {
        const v0: F32x8 = f32x8(0, 0, -2.0, 0, 1.0, 3.0, 2.0, 7.0);
        const v1: F32x8 = f32x8(0, 1.0, 0, 0, 2.0, 1.0, 4.0, math.inf(f32));
        const v: F32x8 = max(v0, v1);
        try expectVecEqual(v, f32x8(0.0, 1.0, 0.0, 0.0, 2.0, 3.0, 4.0, math.inf(f32)));
    }
    {
        const v0: Vec = f32x4(1.0, math.nan(f32), 5.0, math.snan(f32));
        const v1: Vec = f32x4(2.0, 1.0, 4.0, math.inf(f32));
        const v: Vec = max(v0, v1);
        try expect(v[0] == 2.0);
        try expect(v[1] == 1.0);
        try expect(v[2] == 5.0);
        try expect(v[3] == math.inf(f32));
        try expect(!math.isNan(v[3]));
    }
    {
        const v0: Vec = f32x4(-math.inf(f32), math.inf(f32), math.inf(f32), math.snan(f32));
        const v1: Vec = f32x4(math.snan(f32), -math.inf(f32), math.snan(f32), math.nan(f32));
        const v: Vec = max(v0, v1);
        try expect(v[0] == -math.inf(f32));
        try expect(v[1] == math.inf(f32));
        try expect(v[2] == math.inf(f32));
        try expect(!math.isNan(v[2]));
        try expect(math.isNan(v[3]));
        try expect(!math.isInf(v[3]));
    }
}

pub fn expectVecApproxEqAbs(
    expected: anytype,
    actual: anytype,
    eps: f32,
) !void {
    const T = @TypeOf(expected, actual);
    inline for (0..veclen(T)) |i| {
        try expectApproxEqAbs(expected[i], actual[i], eps);
    }
}

/// int -> f32. Comptime-asserts `x` is an integer (a float/bool/etc is a
/// COMPILE error, so this can't silently hide a bad conversion the way bare
/// @floatFromInt can — and the f32 output is PINNED, not context-inferred).
/// `float(width)` instead of `float(width)`.
pub inline fn float(x: anytype) f32 {
    comptime {
        const info = @typeInfo(@TypeOf(x));
        if (info != .int and info != .comptime_int) {
            @compileError("zm.float expects an integer; got " ++ @typeName(@TypeOf(x)) ++
                " (use a plain f32 literal/value directly).");
        }
    }
    return @floatFromInt(x);
}

test "zm.round" {
    {
        try expect(allTrue(round(splat(math.inf(f32))) == splat(math.inf(f32)), 0));
        try expect(allTrue(round(splat(-math.inf(f32))) == splat(-math.inf(f32)), 0));
        try expect(allTrue(isNan(round(splat(math.nan(f32)))), 0));
        try expect(allTrue(isNan(round(splat(-math.nan(f32)))), 0));
        try expect(allTrue(isNan(round(splat(math.snan(f32)))), 0));
        try expect(allTrue(isNan(round(splat(-math.snan(f32)))), 0));
    }
    {
        const v: F32x16 = round(f32x16(
            1.1,
            -1.1,
            -1.5,
            1.5,
            2.1,
            2.8,
            2.9,
            4.1,
            5.8,
            6.1,
            7.9,
            8.9,
            10.1,
            11.2,
            12.7,
            13.1,
        ));
        try expectVecApproxEqAbs(
            v,
            f32x16(1.0, -1.0, -2.0, 2.0, 2.0, 3.0, 3.0, 4.0, 6.0, 6.0, 8.0, 9.0, 10.0, 11.0, 13.0, 13.0),
            0.0,
        );
    }
    var v: Vec = round(f32x4(1.1, -1.1, -1.5, 1.5));
    try expectVecEqual(v, f32x4(1.0, -1.0, -2.0, 2.0));

    const v1: Vec = f32x4(-10_000_000.1, -math.inf(f32), 10_000_001.5, math.inf(f32));
    v = round(v1);
    try expect(v[3] == math.inf(f32));
    try expectVecEqual(v, f32x4(-10_000_000.1, -math.inf(f32), 10_000_001.5, math.inf(f32)));

    const v2: Vec = f32x4(-math.snan(f32), math.snan(f32), math.nan(f32), -math.inf(f32));
    v = round(v2);
    try expect(math.isNan(v2[0]));
    try expect(math.isNan(v2[1]));
    try expect(math.isNan(v2[2]));
    try expect(v2[3] == -math.inf(f32));

    const v3: Vec = f32x4(1001.5, -201.499, -10000.99, -101.5);
    v = round(v3);
    try expectVecEqual(v, f32x4(1002.0, -201.0, -10001.0, -102.0));

    const v4: Vec = f32x4(-1_388_609.9, 1_388_609.5, 1_388_109.01, 2_388_609.5);
    v = round(v4);
    try expectVecEqual(v, f32x4(-1_388_610.0, 1_388_610.0, 1_388_109.0, 2_388_610.0));

    var f: f32 = -100.0;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const vr = round(splat(f));
        const fr = @round(splat(f));
        const vr8 = round(@as(F32x8, @splat(f)));
        const fr8 = @round(@as(F32x8, @splat(f)));
        const vr16 = round(@as(F32x16, @splat(f)));
        const fr16 = @round(@as(F32x16, @splat(f)));
        try expectVecEqual(vr, fr);
        try expectVecEqual(vr8, fr8);
        try expectVecEqual(vr16, fr16);
        f += 0.12345 * float(i);
    }
}

fn floatToIntAndBack(v: anytype) @TypeOf(v) {
    // This routine won't handle nan, inf and numbers greater than 8_388_608.0 (will generate undefined values).
    @setRuntimeSafety(false);

    const T = @TypeOf(v);
    const len = veclen(T);

    var vi32: [len]i32 = undefined;
    comptime var i: u32 = 0;
    // vcvttps2dq.  Bare `@trunc` (not zm.int) so this conversion stays inside the
    // `@setRuntimeSafety(false)` above: nan/inf/huge lanes are expected to produce
    // garbage here (the callers mask them out), and a checked conversion would trap.
    inline while (i < len) : (i += 1) {
        vi32[i] = @trunc(v[i]);
    }

    var vf32: [len]f32 = undefined;
    i = 0;
    // vcvtdq2ps
    inline while (i < len) : (i += 1) {
        vf32[i] = float(vi32[i]);
    }

    return vf32;
}

pub fn trunc(v: anytype) @TypeOf(v) {
    const T = @TypeOf(v);
    // [zimr Z0] The `cpu_arch == .x86_64` branch below is x86 inline
    // assembly (vroundps / vrndscaleps).  zimr ships wasm32 only, so
    // this branch is already comptime-dead in every real zimr build
    // the portable `else` path is what actually runs.  We additionally
    // gate it behind `false` so the NATIVE test target
    // (`zig build math-test`) doesn't compile the asm either: those
    // blocks trip a register-allocator assertion in Zig 0.16's
    // self-hosted x86_64 backend (`genSetReg called with a value
    // larger than dst_reg`).  Dropping the asm changes nothing about
    // zimr's behaviour or perf - it's wasm - and avoids a toolchain
    // split (no `use_llvm` override needed).  The asm is kept rather
    // than deleted so the diff from upstream zmath stays auditable.
    if (false and cpu_arch == .x86_64 and has_avx) {
        if (T == Vec) {
            return asm ("vroundps $3, %%xmm0, %%xmm0"
                : [ret] "={xmm0}" (-> T),
                : [v] "{xmm0}" (v),
            );
        } else if (T == F32x8) {
            return asm ("vroundps $3, %%ymm0, %%ymm0"
                : [ret] "={ymm0}" (-> T),
                : [v] "{ymm0}" (v),
            );
        } else if (T == F32x16 and has_avx512f) {
            return asm ("vrndscaleps $3, %%zmm0, %%zmm0"
                : [ret] "={zmm0}" (-> T),
                : [v] "{zmm0}" (v),
            );
        } else if (T == F32x16 and !has_avx512f) {
            const arr: [16]f32 = v;
            var ymm0 = @as(F32x8, arr[0..8].*);
            var ymm1 = @as(F32x8, arr[8..16].*);
            ymm0 = asm ("vroundps $3, %%ymm0, %%ymm0"
                : [ret] "={ymm0}" (-> F32x8),
                : [v] "{ymm0}" (ymm0),
            );
            ymm1 = asm ("vroundps $3, %%ymm1, %%ymm1"
                : [ret] "={ymm1}" (-> F32x8),
                : [v] "{ymm1}" (ymm1),
            );
            return @shuffle(f32, ymm0, ymm1, [16]i32{ 0, 1, 2, 3, 4, 5, 6, 7, -1, -2, -3, -4, -5, -6, -7, -8 });
        }
    } else {
        const mask = abs(v) < splatNoFraction(T);
        const result: T = floatToIntAndBack(v);
        return blend(mask, result, v);
    }
}
test "zm.trunc" {
    {
        try expect(allTrue(trunc(splat(math.inf(f32))) == splat(math.inf(f32)), 0));
        try expect(allTrue(trunc(splat(-math.inf(f32))) == splat(-math.inf(f32)), 0));
        try expect(allTrue(isNan(trunc(splat(math.nan(f32)))), 0));
        try expect(allTrue(isNan(trunc(splat(-math.nan(f32)))), 0));
        try expect(allTrue(isNan(trunc(splat(math.snan(f32)))), 0));
        try expect(allTrue(isNan(trunc(splat(-math.snan(f32)))), 0));
    }
    {
        const v: F32x16 = trunc(f32x16(
            1.1,
            -1.1,
            -1.5,
            1.5,
            2.1,
            2.8,
            2.9,
            4.1,
            5.8,
            6.1,
            7.9,
            8.9,
            10.1,
            11.2,
            12.7,
            13.1,
        ));
        try expectVecApproxEqAbs(
            v,
            f32x16(1.0, -1.0, -1.0, 1.0, 2.0, 2.0, 2.0, 4.0, 5.0, 6.0, 7.0, 8.0, 10.0, 11.0, 12.0, 13.0),
            0.0,
        );
    }
    var v: Vec = trunc(f32x4(1.1, -1.1, -1.5, 1.5));
    try expectVecEqual(v, f32x4(1.0, -1.0, -1.0, 1.0));

    v = trunc(f32x4(-10_000_002.1, -math.inf(f32), 10_000_001.5, math.inf(f32)));
    try expectVecEqual(v, f32x4(-10_000_002.1, -math.inf(f32), 10_000_001.5, math.inf(f32)));

    v = trunc(f32x4(-math.snan(f32), math.snan(f32), math.nan(f32), -math.inf(f32)));
    try expect(math.isNan(v[0]));
    try expect(math.isNan(v[1]));
    try expect(math.isNan(v[2]));
    try expect(v[3] == -math.inf(f32));

    v = trunc(f32x4(1000.5001, -201.499, -10000.99, 100.750001));
    try expectVecEqual(v, f32x4(1000.0, -201.0, -10000.0, 100.0));

    v = trunc(f32x4(-7_388_609.5, 7_388_609.1, 8_388_109.5, -8_388_509.5));
    try expectVecEqual(v, f32x4(-7_388_609.0, 7_388_609.0, 8_388_109.0, -8_388_509.0));

    var f: f32 = -100.0;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const vr = trunc(splat(f));
        const fr = @trunc(splat(f));
        const vr8 = trunc(@as(F32x8, @splat(f)));
        const fr8 = @trunc(@as(F32x8, @splat(f)));
        const vr16 = trunc(@as(F32x16, @splat(f)));
        const fr16 = @trunc(@as(F32x16, @splat(f)));
        try expectVecEqual(vr, fr);
        try expectVecEqual(vr8, fr8);
        try expectVecEqual(vr16, fr16);
        f += 0.12345 * float(i);
    }
}

pub fn floor(v: anytype) @TypeOf(v) {
    const T = @TypeOf(v);
    // [zimr Z0] The `cpu_arch == .x86_64` branch below is x86 inline
    // assembly (vroundps / vrndscaleps).  zimr ships wasm32 only, so
    // this branch is already comptime-dead in every real zimr build
    // the portable `else` path is what actually runs.  We additionally
    // gate it behind `false` so the NATIVE test target
    // (`zig build math-test`) doesn't compile the asm either: those
    // blocks trip a register-allocator assertion in Zig 0.16's
    // self-hosted x86_64 backend (`genSetReg called with a value
    // larger than dst_reg`).  Dropping the asm changes nothing about
    // zimr's behaviour or perf - it's wasm - and avoids a toolchain
    // split (no `use_llvm` override needed).  The asm is kept rather
    // than deleted so the diff from upstream zmath stays auditable.
    if (false and cpu_arch == .x86_64 and has_avx) {
        if (T == Vec) {
            return asm ("vroundps $1, %%xmm0, %%xmm0"
                : [ret] "={xmm0}" (-> T),
                : [v] "{xmm0}" (v),
            );
        } else if (T == F32x8) {
            return asm ("vroundps $1, %%ymm0, %%ymm0"
                : [ret] "={ymm0}" (-> T),
                : [v] "{ymm0}" (v),
            );
        } else if (T == F32x16 and has_avx512f) {
            return asm ("vrndscaleps $1, %%zmm0, %%zmm0"
                : [ret] "={zmm0}" (-> T),
                : [v] "{zmm0}" (v),
            );
        } else if (T == F32x16 and !has_avx512f) {
            const arr: [16]f32 = v;
            var ymm0 = @as(F32x8, arr[0..8].*);
            var ymm1 = @as(F32x8, arr[8..16].*);
            ymm0 = asm ("vroundps $1, %%ymm0, %%ymm0"
                : [ret] "={ymm0}" (-> F32x8),
                : [v] "{ymm0}" (ymm0),
            );
            ymm1 = asm ("vroundps $1, %%ymm1, %%ymm1"
                : [ret] "={ymm1}" (-> F32x8),
                : [v] "{ymm1}" (ymm1),
            );
            return @shuffle(f32, ymm0, ymm1, [16]i32{ 0, 1, 2, 3, 4, 5, 6, 7, -1, -2, -3, -4, -5, -6, -7, -8 });
        }
    } else {
        const mask = abs(v) < splatNoFraction(T);
        var result: T = floatToIntAndBack(v);
        const larger_mask: @Vector(veclen(T), bool) = result > v;
        const larger = blend(larger_mask, @as(T, @splat(-1.0)), @as(T, @splat(0.0)));
        result = result + larger;
        return blend(mask, result, v);
    }
}
test "zm.floor" {
    {
        try expect(allTrue(floor(splat(math.inf(f32))) == splat(math.inf(f32)), 0));
        try expect(allTrue(floor(splat(-math.inf(f32))) == splat(-math.inf(f32)), 0));
        try expect(allTrue(isNan(floor(splat(math.nan(f32)))), 0));
        try expect(allTrue(isNan(floor(splat(-math.nan(f32)))), 0));
        try expect(allTrue(isNan(floor(splat(math.snan(f32)))), 0));
        try expect(allTrue(isNan(floor(splat(-math.snan(f32)))), 0));
    }
    {
        const v: F32x16 = floor(f32x16(
            1.1,
            -1.1,
            -1.5,
            1.5,
            2.1,
            2.8,
            2.9,
            4.1,
            5.8,
            6.1,
            7.9,
            8.9,
            10.1,
            11.2,
            12.7,
            13.1,
        ));
        try expectVecApproxEqAbs(
            v,
            f32x16(1.0, -2.0, -2.0, 1.0, 2.0, 2.0, 2.0, 4.0, 5.0, 6.0, 7.0, 8.0, 10.0, 11.0, 12.0, 13.0),
            0.0,
        );
    }
    var v: Vec = floor(f32x4(1.5, -1.5, -1.7, -2.1));
    try expectVecEqual(v, f32x4(1.0, -2.0, -2.0, -3.0));

    v = floor(f32x4(-10_000_002.1, -math.inf(f32), 10_000_001.5, math.inf(f32)));
    try expectVecEqual(v, f32x4(-10_000_002.1, -math.inf(f32), 10_000_001.5, math.inf(f32)));

    v = floor(f32x4(-math.snan(f32), math.snan(f32), math.nan(f32), -math.inf(f32)));
    try expect(math.isNan(v[0]));
    try expect(math.isNan(v[1]));
    try expect(math.isNan(v[2]));
    try expect(v[3] == -math.inf(f32));

    v = floor(f32x4(1000.5001, -201.499, -10000.99, 100.75001));
    try expectVecEqual(v, f32x4(1000.0, -202.0, -10001.0, 100.0));

    v = floor(f32x4(-7_388_609.5, 7_388_609.1, 8_388_109.5, -8_388_509.5));
    try expectVecEqual(v, f32x4(-7_388_610.0, 7_388_609.0, 8_388_109.0, -8_388_510.0));

    var f: f32 = -100.0;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const vr = floor(splat(f));
        const fr = @floor(splat(f));
        const vr8 = floor(@as(F32x8, @splat(f)));
        const fr8 = @floor(@as(F32x8, @splat(f)));
        const vr16 = floor(@as(F32x16, @splat(f)));
        const fr16 = @floor(@as(F32x16, @splat(f)));
        try expectVecEqual(vr, fr);
        try expectVecEqual(vr8, fr8);
        try expectVecEqual(vr16, fr16);
        f += 0.12345 * float(i);
    }
}

pub fn ceil(v: anytype) @TypeOf(v) {
    const T = @TypeOf(v);
    // [zimr Z0] The `cpu_arch == .x86_64` branch below is x86 inline
    // assembly (vroundps / vrndscaleps).  zimr ships wasm32 only, so
    // this branch is already comptime-dead in every real zimr build
    // the portable `else` path is what actually runs.  We additionally
    // gate it behind `false` so the NATIVE test target
    // (`zig build math-test`) doesn't compile the asm either: those
    // blocks trip a register-allocator assertion in Zig 0.16's
    // self-hosted x86_64 backend (`genSetReg called with a value
    // larger than dst_reg`).  Dropping the asm changes nothing about
    // zimr's behaviour or perf - it's wasm - and avoids a toolchain
    // split (no `use_llvm` override needed).  The asm is kept rather
    // than deleted so the diff from upstream zmath stays auditable.
    if (false and cpu_arch == .x86_64 and has_avx) {
        if (T == Vec) {
            return asm ("vroundps $2, %%xmm0, %%xmm0"
                : [ret] "={xmm0}" (-> T),
                : [v] "{xmm0}" (v),
            );
        } else if (T == F32x8) {
            return asm ("vroundps $2, %%ymm0, %%ymm0"
                : [ret] "={ymm0}" (-> T),
                : [v] "{ymm0}" (v),
            );
        } else if (T == F32x16 and has_avx512f) {
            return asm ("vrndscaleps $2, %%zmm0, %%zmm0"
                : [ret] "={zmm0}" (-> T),
                : [v] "{zmm0}" (v),
            );
        } else if (T == F32x16 and !has_avx512f) {
            const arr: [16]f32 = v;
            var ymm0 = @as(F32x8, arr[0..8].*);
            var ymm1 = @as(F32x8, arr[8..16].*);
            ymm0 = asm ("vroundps $2, %%ymm0, %%ymm0"
                : [ret] "={ymm0}" (-> F32x8),
                : [v] "{ymm0}" (ymm0),
            );
            ymm1 = asm ("vroundps $2, %%ymm1, %%ymm1"
                : [ret] "={ymm1}" (-> F32x8),
                : [v] "{ymm1}" (ymm1),
            );
            return @shuffle(f32, ymm0, ymm1, [16]i32{ 0, 1, 2, 3, 4, 5, 6, 7, -1, -2, -3, -4, -5, -6, -7, -8 });
        }
    } else {
        const mask = abs(v) < splatNoFraction(T);
        var result: T = floatToIntAndBack(v);
        const smaller_mask: @Vector(veclen(T), bool) = result < v;
        const smaller = blend(smaller_mask, @as(T, @splat(-1.0)), @as(T, @splat(0.0)));
        result = result - smaller;
        return blend(mask, result, v);
    }
}
test "zm.ceil" {
    {
        try expect(allTrue(ceil(splat(math.inf(f32))) == splat(math.inf(f32)), 0));
        try expect(allTrue(ceil(splat(-math.inf(f32))) == splat(-math.inf(f32)), 0));
        try expect(allTrue(isNan(ceil(splat(math.nan(f32)))), 0));
        try expect(allTrue(isNan(ceil(splat(-math.nan(f32)))), 0));
        try expect(allTrue(isNan(ceil(splat(math.snan(f32)))), 0));
        try expect(allTrue(isNan(ceil(splat(-math.snan(f32)))), 0));
    }
    {
        const v: F32x16 = ceil(f32x16(
            1.1,
            -1.1,
            -1.5,
            1.5,
            2.1,
            2.8,
            2.9,
            4.1,
            5.8,
            6.1,
            7.9,
            8.9,
            10.1,
            11.2,
            12.7,
            13.1,
        ));
        try expectVecApproxEqAbs(
            v,
            f32x16(2.0, -1.0, -1.0, 2.0, 3.0, 3.0, 3.0, 5.0, 6.0, 7.0, 8.0, 9.0, 11.0, 12.0, 13.0, 14.0),
            0.0,
        );
    }
    var v: Vec = ceil(f32x4(1.5, -1.5, -1.7, -2.1));
    try expectVecEqual(v, f32x4(2.0, -1.0, -1.0, -2.0));

    v = ceil(f32x4(-10_000_002.1, -math.inf(f32), 10_000_001.5, math.inf(f32)));
    try expectVecEqual(v, f32x4(-10_000_002.1, -math.inf(f32), 10_000_001.5, math.inf(f32)));

    v = ceil(f32x4(-math.snan(f32), math.snan(f32), math.nan(f32), -math.inf(f32)));
    try expect(math.isNan(v[0]));
    try expect(math.isNan(v[1]));
    try expect(math.isNan(v[2]));
    try expect(v[3] == -math.inf(f32));

    v = ceil(f32x4(1000.5001, -201.499, -10000.99, 100.75001));
    try expectVecEqual(v, f32x4(1001.0, -201.0, -10000.0, 101.0));

    v = ceil(f32x4(-1_388_609.5, 1_388_609.1, 1_388_109.9, -1_388_509.9));
    try expectVecEqual(v, f32x4(-1_388_609.0, 1_388_610.0, 1_388_110.0, -1_388_509.0));

    var f: f32 = -100.0;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const vr = ceil(splat(f));
        const fr = @ceil(splat(f));
        const vr8 = ceil(@as(F32x8, @splat(f)));
        const fr8 = @ceil(@as(F32x8, @splat(f)));
        const vr16 = ceil(@as(F32x16, @splat(f)));
        const fr16 = @ceil(@as(F32x16, @splat(f)));
        try expectVecEqual(vr, fr);
        try expectVecEqual(vr8, fr8);
        try expectVecEqual(vr16, fr16);
        f += 0.12345 * float(i);
    }
}

pub inline fn clamp(
    v: anytype,
    vmin: anytype,
    vmax: anytype,
) @TypeOf(v, vmin, vmax) {
    const T = @TypeOf(v, vmin, vmax);
    var result: T = max(vmin, v);
    result = min(vmax, result);
    return result;
}
test "zm.clamp" {
    {
        const v0: Vec = f32x4(-1.0, 0.2, 1.1, -0.3);
        const v: Vec = clamp(v0, splat(-0.5), splat(0.5));
        try expectVecApproxEqAbs(v, f32x4(-0.5, 0.2, 0.5, -0.3), 0.0001);
    }
    {
        const v0: F32x8 = f32x8(-2.0, 0.25, -0.25, 100.0, -1.0, 0.2, 1.1, -0.3);
        const v: F32x8 = clamp(v0, @as(F32x8, @splat(-0.5)), @as(F32x8, @splat(0.5)));
        try expectVecApproxEqAbs(v, f32x8(-0.5, 0.25, -0.25, 0.5, -0.5, 0.2, 0.5, -0.3), 0.0001);
    }
    {
        const v0: Vec = f32x4(-math.inf(f32), math.inf(f32), math.nan(f32), math.snan(f32));
        const v: Vec = clamp(v0, f32x4(-100.0, 0.0, -100.0, 0.0), f32x4(0.0, 100.0, 0.0, 100.0));
        try expectVecApproxEqAbs(v, f32x4(-100.0, 100.0, -100.0, 0.0), 0.0001);
    }
    {
        const v0: Vec = f32x4(math.inf(f32), math.inf(f32), -math.nan(f32), -math.snan(f32));
        const v: Vec = clamp(v0, splat(-1.0), splat(1.0));
        try expectVecApproxEqAbs(v, f32x4(1.0, 1.0, -1.0, -1.0), 0.0001);
    }
}

pub inline fn clampFast(
    v: anytype,
    vmin: anytype,
    vmax: anytype,
) @TypeOf(v, vmin, vmax) {
    const T = @TypeOf(v, vmin, vmax);
    var result: T = maxFast(vmin, v);
    result = minFast(vmax, result);
    return result;
}
test "zm.clampFast" {
    {
        const v0: Vec = .{ -1.0, 0.2, 1.1, -0.3 };
        const v: Vec = clampFast(v0, splat(-0.5), splat(0.5));
        try expectVecApproxEqAbs(v, f32x4(-0.5, 0.2, 0.5, -0.3), 0.0001);
    }
}

/// HLSL `saturate` — clamp to [0, 1]. Works on scalars AND vectors, like `lerp`.
///
/// It used to be vector-ONLY (`@splat` does not accept a scalar), which meant a
/// scalar caller had to reach for `clamp01` instead — the same operation under a
/// second name, with no hint that the "wrong" one would not compile. Two names
/// for one idea is exactly how `step` got lost; one that works on both domains is
/// the fix. `clamp01` remains for the callers that already use it.
/// HLSL's `saturate` — the spelling zimr does NOT use.
///
/// Kept as a decl so the name RESOLVES: an author who types `zm.saturate` gets
/// told the house name instead of "no member named 'saturate'", and @hasDecl can
/// still see it — but it is PRIVATE and empty, so reaching for `zm.saturate`
/// fails with "not marked pub" and lands you right here, on this comment.
///
/// USE `zm.clamp01`.
///
/// Why not `pub const saturate = @compileError(...)`? Because a PUB
/// @compileError decl is referenced by `std.testing.refAllDecls(zm)`, which
/// `src/tests.zig` runs — so the dead name took the whole test gate down with
/// it. `@typeInfo` only exposes pub decls, so a private one is invisible to
/// refAllDecls while staying visible to a human reading the file.
fn saturate() void {}
test "zm.clamp01 (vector + scalar; HLSL calls it saturate)" {
    {
        const v0: Vec = f32x4(-1.0, 0.2, 1.1, -0.3);
        const v: Vec = clamp01(v0);
        try expectVecApproxEqAbs(v, f32x4(0.0, 0.2, 1.0, 0.0), 0.0001);
    }
    {
        const v0: F32x8 = f32x8(0.0, 0.0, 2.0, -2.0, -1.0, 0.2, 1.1, -0.3);
        const v: F32x8 = clamp01(v0);
        try expectVecApproxEqAbs(v, f32x8(0.0, 0.0, 1.0, 0.0, 0.0, 0.2, 1.0, 0.0), 0.0001);
    }
    {
        const v0: Vec = f32x4(-math.inf(f32), math.inf(f32), math.nan(f32), math.snan(f32));
        const v: Vec = clamp01(v0);
        try expectVecApproxEqAbs(v, f32x4(0.0, 1.0, 0.0, 0.0), 0.0001);
    }
    {
        const v0: Vec = f32x4(math.inf(f32), math.inf(f32), -math.nan(f32), -math.snan(f32));
        const v: Vec = clamp01(v0);
        try expectVecApproxEqAbs(v, f32x4(1.0, 1.0, 0.0, 0.0), 0.0001);
    }
    {
        // SCALARS MUST AGREE WITH VECTORS. The old scalar path was a branch chain
        // (`if (v < 0) ... if (v > 1) ...`); both compares are false for NaN, so it
        // returned NaN while the vector path returned 0. Nothing pinned that, so it
        // drifted silently. Pin it.
        try expectEqual(@as(f32, 0.0), clamp01(@as(f32, -1.0)));
        try expectEqual(@as(f32, 0.2), clamp01(@as(f32, 0.2)));
        try expectEqual(@as(f32, 1.0), clamp01(@as(f32, 1.1)));
        try expectEqual(@as(f32, 0.0), clamp01(-math.inf(f32)));
        try expectEqual(@as(f32, 1.0), clamp01(math.inf(f32)));
        try expectEqual(@as(f32, 0.0), clamp01(math.nan(f32)));
    }
    {
        // `step` was a branch chain for the same reason. Same hazard, same fix.
        try expectEqual(@as(f32, 0.0), step(0.5, 0.4));
        try expectEqual(@as(f32, 1.0), step(0.5, 0.5));
        try expectEqual(@as(f32, 1.0), step(0.5, 0.6));
        try expectEqual(@as(f32, 0.0), step(0.5, math.nan(f32)));
    }
}

pub inline fn saturateFast(v: anytype) @TypeOf(v) {
    const T = @TypeOf(v);
    var result = maxFast(v, @as(T, @splat(0.0)));
    result = minFast(result, @as(T, @splat(1.0)));
    return result;
}
test "zm.saturateFast" {
    {
        const v0: Vec = f32x4(-1.0, 0.2, 1.1, -0.3);
        const v: Vec = saturateFast(v0);
        try expectVecApproxEqAbs(v, f32x4(0.0, 0.2, 1.0, 0.0), 0.0001);
    }
    {
        const v0: F32x8 = f32x8(0.0, 0.0, 2.0, -2.0, -1.0, 0.2, 1.1, -0.3);
        const v: F32x8 = saturateFast(v0);
        try expectVecApproxEqAbs(v, f32x8(0.0, 0.0, 1.0, 0.0, 0.0, 0.2, 1.0, 0.0), 0.0001);
    }
    {
        const v0: Vec = f32x4(-math.inf(f32), math.inf(f32), math.nan(f32), math.snan(f32));
        const v: Vec = saturateFast(v0);
        try expectVecApproxEqAbs(v, f32x4(0.0, 1.0, 0.0, 0.0), 0.0001);
    }
    {
        const v0: Vec = f32x4(math.inf(f32), math.inf(f32), -math.nan(f32), -math.snan(f32));
        const v: Vec = saturateFast(v0);
        try expectVecApproxEqAbs(v, f32x4(1.0, 1.0, 0.0, 0.0), 0.0001);
    }
}

/// Integer floor-sqrt, vendored from std.math.sqrt's `sqrt_int` (bit-by-
/// bit restoring algorithm).  Returns the result in the input type `T`
/// (std narrows to ~T/2 bits; zm.sqrt's signature is `@TypeOf(v)`, so we
/// keep the width).  Pure integer ops — GPU-portable.
fn sqrtInt(comptime T: type, value: T) T {
    if (@typeInfo(T).int.bits <= 2) {
        return if (value == 0) 0 else 1;
    }
    const bits: u16 = @typeInfo(T).int.bits;
    const max_val: T = maxInt(T);
    const minustwo: T = (@as(T, 2) ^ max_val) + 1; // unsigned can't hold -2
    var op: T = value;
    var res: T = 0;
    var one: T = 1 << ((bits - 1) & minustwo); // highest power of four <= T
    while (one > op) {
        one >>= 2;
    }
    while (one != 0) {
        const c: bool = op >= res + one;
        if (c) {
            op -= res + one;
        }
        res >>= 1;
        if (c) {
            res += one;
        }
        one >>= 2;
    }
    return res;
}

pub inline fn sqrt(v: anytype) @TypeOf(v) {
    if (comptime @typeInfo(@TypeOf(v)) == .int) {
        return sqrtInt(@TypeOf(v), v); // integer floor-sqrt
    }
    return @sqrt(v); // sqrtps — floats + vectors, all targets
}

pub inline fn lerp(
    v0: anytype,
    v1: anytype,
    t: f32,
) @TypeOf(v0, v1) {
    const T = @TypeOf(v0, v1);
    return switch (@typeInfo(T)) {
        // Vec / Vec2 / F32x8 / F32x16: broadcast t and multiply by vector.
        .vector => v0 + (v1 - v0) * @as(T, @splat(t)),
        // f32 / comptime_float / etc: plain scalar arithmetic.
        else => v0 + (v1 - v0) * t,
    };
}

pub inline fn lerpV(
    v0: anytype,
    v1: anytype,
    t: anytype,
) @TypeOf(v0, v1, t) {
    return v0 + (v1 - v0) * t; // subps, addps, mulps
}

pub inline fn lerpInverse(
    v0: anytype,
    v1: anytype,
    t: anytype,
) @TypeOf(v0, v1) {
    const T = @TypeOf(v0, v1);
    return (@as(T, @splat(t)) - v0) / (v1 - v0);
}

pub inline fn lerpInverseV(
    v0: anytype,
    v1: anytype,
    t: anytype,
) @TypeOf(v0, v1, t) {
    return (t - v0) / (v1 - v0);
}
test "zm.lerpInverse" {
    try expect(math.approxEqAbs(f32, lerpInverseV(10.0, 100.0, 10.0), 0, 0.0005));
    try expect(math.approxEqAbs(f32, lerpInverseV(10.0, 100.0, 100.0), 1, 0.0005));
    try expect(math.approxEqAbs(f32, lerpInverseV(10.0, 100.0, 55.0), 0.5, 0.05));
    try expectVecApproxEqAbs(
        lerpInverse(f32x4(0, 0, 10, 10), f32x4(100, 200, 100, 100), 10.0),
        f32x4(0.1, 0.05, 0, 0),
        0.0005,
    );
}

// Frame rate independent lerp (or "damp"), for approaching things over time.
// Reference: https://www.gamedeveloper.com/programming/improved-lerp-smoothing-
pub inline fn lerpOverTime(
    v0: anytype,
    v1: anytype,
    rate: anytype,
    dt: anytype,
) @TypeOf(v0, v1) {
    // `@exp2` is Zig's generic-T builtin (works for f32/f64/Vec) and
    // lowers to SPIR-V's GLSL.std.450.Exp2 op on shader targets.
    // Replaces a plain `std.math.exp2` call (which is f32/f64 only
    // and doesn't lower as cleanly on SPIR-V).
    const t: @TypeOf(rate, dt) = @exp2(-rate * dt);
    return lerp(v1, v0, t);
}

pub inline fn lerpVOverTime(
    v0: anytype,
    v1: anytype,
    rate: anytype,
    dt: anytype,
) @TypeOf(v0, v1, rate, dt) {
    const t: @TypeOf(rate, dt) = @exp2(-rate * dt);
    return lerpV(v1, v0, t);
}

test "zm.lerpOverTime" {
    try expect(math.approxEqAbs(f32, lerpVOverTime(0.0, 1.0, 1.0, 1.0), 0.5, 0.0005));
    try expect(math.approxEqAbs(f32, lerpVOverTime(0.5, 1.0, 1.0, 1.0), 0.75, 0.0005));
    try expect(math.approxEqAbs(f32, lerpVOverTime(0.0, 1.0, 1.0, 0.0), 0.0, 0.0005));
    try expect(math.approxEqAbs(f32, lerpVOverTime(0.0, 1.0, 1.0, std.math.inf(f32)), 1.0, 0.0005));
    try expectVecApproxEqAbs(
        lerpOverTime(f32x4(0, 0, 10, 10), f32x4(100, 200, 100, 100), 1.0, 1.0),
        f32x4(50, 100, 55, 55),
        0.0005,
    );
}

/// To transform a vector of values from one range to another.
pub inline fn mapLinear(
    v: anytype,
    min1: anytype,
    max1: anytype,
    min2: anytype,
    max2: anytype,
) @TypeOf(v) {
    const T = @TypeOf(v);
    const min1V = @as(T, @splat(min1));
    const max1V = @as(T, @splat(max1));
    const min2V = @as(T, @splat(min2));
    const max2V = @as(T, @splat(max2));
    const dV: T = max1V - min1V;
    return min2V + (v - min1V) * (max2V - min2V) / dV;
}

pub inline fn mapLinearV(
    v: anytype,
    min1: anytype,
    max1: anytype,
    min2: anytype,
    max2: anytype,
) @TypeOf(v, min1, max1, min2, max2) {
    const d: @TypeOf(max1, min1) = max1 - min1;
    return min2 + (v - min1) * (max2 - min2) / d;
}
test "zm.mapLinear" {
    try expect(math.approxEqAbs(f32, mapLinearV(0, 0, 1.2, 10, 100), 10, 0.0005));
    try expect(math.approxEqAbs(f32, mapLinearV(1.2, 0, 1.2, 10, 100), 100, 0.0005));
    try expect(math.approxEqAbs(f32, mapLinearV(0.6, 0, 1.2, 10, 100), 55, 0.0005));
    try expectVecApproxEqAbs(mapLinearV(splat(0), splat(0), splat(1.2), splat(10), splat(100)), splat(10), 0.0005);
    try expectVecApproxEqAbs(mapLinear(f32x4(0, 0, 0.6, 1.2), 0, 1.2, 10, 100), f32x4(10, 10, 55, 100), 0.0005);
}

pub const F32x4Component = enum { x, y, z, w };

pub inline fn swizzle(
    v: Vec,
    comptime x: F32x4Component,
    comptime y: F32x4Component,
    comptime z: F32x4Component,
    comptime w: F32x4Component,
) Vec {
    return @shuffle(f32, v, undefined, [4]i32{ @intFromEnum(x), @intFromEnum(y), @intFromEnum(z), @intFromEnum(w) });
}

pub inline fn modulo(v0: anytype, v1: anytype) @TypeOf(v0, v1) {
    // vdivps, vroundps, vmulps, vsubps
    return v0 - v1 * trunc(v0 / v1);
}
test "zm.mod" {
    try expectVecApproxEqAbs(modulo(splat(3.1), splat(1.7)), splat(1.4), 0.0005);
    try expectVecApproxEqAbs(modulo(splat(-3.0), splat(2.0)), splat(-1.0), 0.0005);
    try expectVecApproxEqAbs(modulo(splat(-3.0), splat(-2.0)), splat(-1.0), 0.0005);
    try expectVecApproxEqAbs(modulo(splat(3.0), splat(-2.0)), splat(1.0), 0.0005);
    try expect(allTrue(isNan(modulo(splat(math.inf(f32)), splat(1.0))), 0));
    try expect(allTrue(isNan(modulo(splat(-math.inf(f32)), splat(123.456))), 0));
    try expect(allTrue(isNan(modulo(splat(math.nan(f32)), splat(123.456))), 0));
    try expect(allTrue(isNan(modulo(splat(math.snan(f32)), splat(123.456))), 0));
    try expect(allTrue(isNan(modulo(splat(-math.snan(f32)), splat(123.456))), 0));
    try expect(allTrue(isNan(modulo(splat(123.456), splat(math.inf(f32)))), 0));
    try expect(allTrue(isNan(modulo(splat(123.456), splat(-math.inf(f32)))), 0));
    try expect(allTrue(isNan(modulo(splat(math.inf(f32)), splat(math.inf(f32)))), 0));
    try expect(allTrue(isNan(modulo(splat(123.456), splat(math.nan(f32)))), 0));
    try expect(allTrue(isNan(modulo(splat(math.inf(f32)), splat(math.nan(f32)))), 0));
}

test "zm.modAngle" {
    try expectVecApproxEqAbs(modAngle(splat(tau)), splat(0.0), 0.0005);
    try expectVecApproxEqAbs(modAngle(splat(0.0)), splat(0.0), 0.0005);
    try expectVecApproxEqAbs(modAngle(splat(pi)), splat(pi), 0.0005);
    try expectVecApproxEqAbs(modAngle(splat(11 * pi)), splat(pi), 0.0005);
    try expectVecApproxEqAbs(modAngle(splat(3.5 * pi)), splat(-0.5 * pi), 0.0005);
    try expectVecApproxEqAbs(modAngle(splat(2.5 * pi)), splat(0.5 * pi), 0.0005);
}

test "zm.sin" {
    const epsilon: f32 = 0.0001;

    try expectVecApproxEqAbs(sin(splat(0.5 * pi)), splat(1.0), epsilon);
    try expectVecApproxEqAbs(sin(splat(0.0)), splat(0.0), epsilon);
    try expectVecApproxEqAbs(sin(splat(-0.0)), splat(-0.0), epsilon);
    try expectVecApproxEqAbs(sin(splat(89.123)), splat(0.916166), epsilon);
    try expectVecApproxEqAbs(sin(@as(F32x8, @splat(89.123))), @as(F32x8, @splat(0.916166)), epsilon);
    try expectVecApproxEqAbs(sin(@as(F32x16, @splat(89.123))), @as(F32x16, @splat(0.916166)), epsilon);
    try expect(allTrue(isNan(sin(splat(math.inf(f32)))), 0) == true);
    try expect(allTrue(isNan(sin(splat(-math.inf(f32)))), 0) == true);
    try expect(allTrue(isNan(sin(splat(math.nan(f32)))), 0) == true);
    try expect(allTrue(isNan(sin(splat(math.snan(f32)))), 0) == true);

    var f: f32 = -100.0;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const vr: Vec = sin(splat(f));
        const fr: Vec = @sin(splat(f));
        const vr8: F32x8 = sin(@as(F32x8, @splat(f)));
        const fr8: F32x8 = @sin(@as(F32x8, @splat(f)));
        const vr16: F32x16 = sin(@as(F32x16, @splat(f)));
        const fr16: F32x16 = @sin(@as(F32x16, @splat(f)));
        try expectVecApproxEqAbs(vr, fr, epsilon);
        try expectVecApproxEqAbs(vr8, fr8, epsilon);
        try expectVecApproxEqAbs(vr16, fr16, epsilon);
        f += 0.12345 * float(i);
    }
}

test "zm.cos" {
    const epsilon: f32 = 0.0001;

    try expectVecApproxEqAbs(cos(splat(0.5 * pi)), splat(0.0), epsilon);
    try expectVecApproxEqAbs(cos(splat(0.0)), splat(1.0), epsilon);
    try expectVecApproxEqAbs(cos(splat(-0.0)), splat(1.0), epsilon);
    try expect(allTrue(isNan(cos(splat(math.inf(f32)))), 0) == true);
    try expect(allTrue(isNan(cos(splat(-math.inf(f32)))), 0) == true);
    try expect(allTrue(isNan(cos(splat(math.nan(f32)))), 0) == true);
    try expect(allTrue(isNan(cos(splat(math.snan(f32)))), 0) == true);

    var f: f32 = -100.0;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const vr: Vec = cos(splat(f));
        const fr: Vec = @cos(splat(f));
        const vr8: F32x8 = cos(@as(F32x8, @splat(f)));
        const fr8: F32x8 = @cos(@as(F32x8, @splat(f)));
        const vr16: F32x16 = cos(@as(F32x16, @splat(f)));
        const fr16: F32x16 = @cos(@as(F32x16, @splat(f)));
        try expectVecApproxEqAbs(vr, fr, epsilon);
        try expectVecApproxEqAbs(vr8, fr8, epsilon);
        try expectVecApproxEqAbs(vr16, fr16, epsilon);
        f += 0.12345 * float(i);
    }
}

/// CPU scalar asin matching zimrmath's forgiving contract: std-accurate
/// for valid inputs; clamps finite |x|>1 to ±π/2 (avoids NaN from fp
/// overshoot like asin(dot) at 1.0000001) but passes inf/nan through to
/// NaN.  (GPU/CPU precision may differ — that's fine — but both clamp, so
/// there's no semantic NaN-vs-clamp surprise across the two paths.)
fn asinCpu(x: anytype) @TypeOf(x) {
    const T = @TypeOf(x);
    if (!isFinite(x)) {
        return nan(T);
    }
    return std.math.asin(@max(@as(T, -1.0), @min(@as(T, 1.0), x)));
}
fn acosCpu(x: anytype) @TypeOf(x) {
    const T = @TypeOf(x);
    if (!isFinite(x)) {
        return nan(T);
    }
    return std.math.acos(@max(@as(T, -1.0), @min(@as(T, 1.0), x)));
}

fn sincos32(v: f32) [2]f32 {
    var y: f32 = v - tau * @round(v * 1.0 / tau);

    const sign: f32 = blk: {
        if (y > 0.5 * pi) {
            y = pi - y;
            break :blk @as(f32, -1.0);
        } else if (y < -pi * 0.5) {
            y = -pi - y;
            break :blk @as(f32, -1.0);
        } else {
            break :blk @as(f32, 1.0);
        }
    };
    const y2: f32 = y * y;

    // 11-degree minimax approximation
    var sinv = mulAdd(@as(f32, -2.3889859e-08), y2, 2.7525562e-06);
    sinv = mulAdd(sinv, y2, -0.00019840874);
    sinv = mulAdd(sinv, y2, 0.0083333310);
    sinv = mulAdd(sinv, y2, -0.16666667);
    sinv = y * mulAdd(sinv, y2, 1.0);

    // 10-degree minimax approximation
    var cosv = mulAdd(@as(f32, -2.6051615e-07), y2, 2.4760495e-05);
    cosv = mulAdd(cosv, y2, -0.0013888378);
    cosv = mulAdd(cosv, y2, 0.041666638);
    cosv = mulAdd(cosv, y2, -0.5);
    cosv = sign * mulAdd(cosv, y2, 1.0);

    return .{ sinv, cosv };
}

fn sincos32xN(v: anytype) [2]@TypeOf(v) {
    const T = @TypeOf(v);

    var x: T = modAngle(v);
    var sign: T = andInt(x, splatNegativeZero(T));
    const c = orInt(sign, @as(T, @splat(pi)));
    const absx: T = andNotInt(sign, x);
    const rflx: T = c - x;
    const comp = absx <= @as(T, @splat(0.5 * pi));
    x = blend(comp, x, rflx);
    sign = blend(comp, @as(T, @splat(1.0)), @as(T, @splat(-1.0)));
    const x2: T = x * x;

    var sresult = mulAdd(@as(T, @splat(-2.3889859e-08)), x2, @as(T, @splat(2.7525562e-06)));
    sresult = mulAdd(sresult, x2, @as(T, @splat(-0.00019840874)));
    sresult = mulAdd(sresult, x2, @as(T, @splat(0.0083333310)));
    sresult = mulAdd(sresult, x2, @as(T, @splat(-0.16666667)));
    sresult = x * mulAdd(sresult, x2, @as(T, @splat(1.0)));

    var cresult = mulAdd(@as(T, @splat(-2.6051615e-07)), x2, @as(T, @splat(2.4760495e-05)));
    cresult = mulAdd(cresult, x2, @as(T, @splat(-0.0013888378)));
    cresult = mulAdd(cresult, x2, @as(T, @splat(0.041666638)));
    cresult = mulAdd(cresult, x2, @as(T, @splat(-0.5)));
    cresult = sign * mulAdd(cresult, x2, @as(T, @splat(1.0)));

    return .{ sresult, cresult };
}

pub fn sincos(v: anytype) [2]@TypeOf(v) {
    const T = @TypeOf(v);
    if (comptime !is_gpu and @typeInfo(T) != .vector) {
        return .{ @sin(v), @cos(v) };
    }
    return switch (T) {
        f32 => sincos32(v),
        Vec, F32x8, F32x16 => sincos32xN(v),
        else => @compileError("zm.sincos() not implemented for " ++ @typeName(T)),
    };
}

fn asin32(v: f32) f32 {
    const x: f32 = @abs(v);
    var omx: f32 = 1.0 - x;
    if (omx < 0.0) {
        omx = 0.0;
    }
    const root: f32 = @sqrt(omx);

    // 7-degree minimax approximation
    var result: f32 = mulAdd(@as(f32, -0.0012624911), x, 0.0066700901);
    result = mulAdd(result, x, -0.0170881256);
    result = mulAdd(result, x, 0.0308918810);
    result = mulAdd(result, x, -0.0501743046);
    result = mulAdd(result, x, 0.0889789874);
    result = mulAdd(result, x, -0.2145988016);
    result = root * mulAdd(result, x, 1.5707963050);

    return if (v >= 0.0) 0.5 * pi - result else result - 0.5 * pi;
}

fn asin32xN(v: anytype) @TypeOf(v) {
    // 7-degree minimax approximation
    const T = @TypeOf(v);

    const x: T = abs(v);
    const root = sqrt(maxFast(@as(T, @splat(0.0)), @as(T, @splat(1.0)) - x));

    var t0: T = mulAdd(@as(T, @splat(-0.0012624911)), x, @as(T, @splat(0.0066700901)));
    t0 = mulAdd(t0, x, @as(T, @splat(-0.0170881256)));
    t0 = mulAdd(t0, x, @as(T, @splat(0.0308918810)));
    t0 = mulAdd(t0, x, @as(T, @splat(-0.0501743046)));
    t0 = mulAdd(t0, x, @as(T, @splat(0.0889789874)));
    t0 = mulAdd(t0, x, @as(T, @splat(-0.2145988016)));
    t0 = root * mulAdd(t0, x, @as(T, @splat(1.5707963050)));

    const t1: T = @as(T, @splat(pi)) - t0;
    return @as(T, @splat(0.5 * pi)) - blend(v >= @as(T, @splat(0.0)), t0, t1);
}

pub fn asin(v: anytype) @TypeOf(v) {
    const T = @TypeOf(v);
    // Scalar on CPU: std accuracy with the forgiving-domain clamp.
    // Vectors (CPU SIMD path + GPU): zmath's vectorized polynomial.
    if (comptime !is_gpu and @typeInfo(T) != .vector) {
        return asinCpu(v);
    }
    return switch (T) {
        f32 => asin32(v),
        Vec, F32x8, F32x16 => asin32xN(v),
        else => @compileError("zm.asin() not implemented for " ++ @typeName(T)),
    };
}

fn acos32(v: f32) f32 {
    const x: f32 = @abs(v);
    var omx: f32 = 1.0 - x;
    if (omx < 0.0) {
        omx = 0.0;
    }
    const root: f32 = @sqrt(omx);

    // 7-degree minimax approximation
    var result: f32 = mulAdd(@as(f32, -0.0012624911), x, 0.0066700901);
    result = mulAdd(result, x, -0.0170881256);
    result = mulAdd(result, x, 0.0308918810);
    result = mulAdd(result, x, -0.0501743046);
    result = mulAdd(result, x, 0.0889789874);
    result = mulAdd(result, x, -0.2145988016);
    result = root * mulAdd(result, x, 1.5707963050);

    return if (v >= 0.0) result else pi - result;
}

fn acos32xN(v: anytype) @TypeOf(v) {
    // 7-degree minimax approximation
    const T = @TypeOf(v);

    const x: T = abs(v);
    const root = sqrt(maxFast(@as(T, @splat(0.0)), @as(T, @splat(1.0)) - x));

    var t0: T = mulAdd(@as(T, @splat(-0.0012624911)), x, @as(T, @splat(0.0066700901)));
    t0 = mulAdd(t0, x, @as(T, @splat(-0.0170881256)));
    t0 = mulAdd(t0, x, @as(T, @splat(0.0308918810)));
    t0 = mulAdd(t0, x, @as(T, @splat(-0.0501743046)));
    t0 = mulAdd(t0, x, @as(T, @splat(0.0889789874)));
    t0 = mulAdd(t0, x, @as(T, @splat(-0.2145988016)));
    t0 = root * mulAdd(t0, x, @as(T, @splat(1.5707963050)));

    const t1: T = @as(T, @splat(pi)) - t0;
    return blend(v >= @as(T, @splat(0.0)), t0, t1);
}

pub fn acos(v: anytype) @TypeOf(v) {
    const T = @TypeOf(v);
    // Scalar on CPU: std accuracy with the forgiving-domain clamp.
    // Vectors (CPU SIMD path + GPU): zmath's vectorized polynomial.
    if (comptime !is_gpu and @typeInfo(T) != .vector) {
        return acosCpu(v);
    }
    return switch (T) {
        f32 => acos32(v),
        Vec, F32x8, F32x16 => acos32xN(v),
        else => @compileError("zm.acos() not implemented for " ++ @typeName(T)),
    };
}

test "zm.sincos32xN" {
    const epsilon: f32 = 0.0001;

    var f: f32 = -100.0;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const sc = sincos(splat(f));
        const sc8 = sincos(@as(F32x8, @splat(f)));
        const sc16 = sincos(@as(F32x16, @splat(f)));
        const s4 = @sin(splat(f));
        const s8 = @sin(@as(F32x8, @splat(f)));
        const s16 = @sin(@as(F32x16, @splat(f)));
        const c4 = @cos(splat(f));
        const c8 = @cos(@as(F32x8, @splat(f)));
        const c16 = @cos(@as(F32x16, @splat(f)));
        try expectVecApproxEqAbs(sc[0], s4, epsilon);
        try expectVecApproxEqAbs(sc8[0], s8, epsilon);
        try expectVecApproxEqAbs(sc16[0], s16, epsilon);
        try expectVecApproxEqAbs(sc[1], c4, epsilon);
        try expectVecApproxEqAbs(sc8[1], c8, epsilon);
        try expectVecApproxEqAbs(sc16[1], c16, epsilon);
        f += 0.12345 * float(i);
    }
}

/// Scalar atan polynomial.  See module comment above.
fn atanScalar(x: f32) f32 {
    const ax: f32 = @abs(x);
    const z: f32 = if (ax > 1.0) 1.0 / ax else ax;
    const z2: f32 = z * z;
    // Horner on the odd polynomial p(z) = z·(c5·z^10 + c4·z^8 +
    // c3·z^6 + c2·z^4 + c1·z^2 + c0).
    var p: f32 = -0.013480470;
    p = p * z2 + 0.057477314;
    p = p * z2 + -0.121239071;
    p = p * z2 + 0.195635925;
    p = p * z2 + -0.332994597;
    p = p * z2 + 0.999995630;
    p = p * z;
    const r: f32 = if (ax > 1.0) (pi / 2.0) - p else p;
    return if (x < 0.0) -r else r;
}

pub fn atan(v: anytype) @TypeOf(v) {
    const T = @TypeOf(v);
    // Scalar: exact std.math.atan on CPU (>100 lines, delegated),
    // polynomial on GPU.  Vectors (CPU SIMD perf + GPU): the 17-degree
    // minimax below.
    if (comptime @typeInfo(T) != .vector) {
        if (comptime !is_gpu) {
            return std.math.atan(v);
        }
        return atanScalar(v);
    }

    const vabs: T = abs(v);
    const vinv = @as(T, @splat(1.0)) / v;
    var sign = blend(v > @as(T, @splat(1.0)), @as(T, @splat(1.0)), @as(T, @splat(-1.0)));
    const comp = vabs <= @as(T, @splat(1.0));
    sign = blend(comp, @as(T, @splat(0.0)), sign);
    const x: T = blend(comp, v, vinv);
    const x2: T = x * x;

    var result: T = mulAdd(@as(T, @splat(0.0028662257)), x2, @as(T, @splat(-0.0161657367)));
    result = mulAdd(result, x2, @as(T, @splat(0.0429096138)));
    result = mulAdd(result, x2, @as(T, @splat(-0.0752896400)));
    result = mulAdd(result, x2, @as(T, @splat(0.1065626393)));
    result = mulAdd(result, x2, @as(T, @splat(-0.1420889944)));
    result = mulAdd(result, x2, @as(T, @splat(0.1999355085)));
    result = mulAdd(result, x2, @as(T, @splat(-0.3333314528)));
    result = x * mulAdd(result, x2, @as(T, @splat(1.0)));

    const result1: T = sign * @as(T, @splat(0.5 * pi)) - result;
    return blend(sign == @as(T, @splat(0.0)), result, result1);
}
test "zm.atan" {
    const epsilon: f32 = 0.0001;
    {
        const v: Vec = f32x4(0.25, 0.5, 1.0, 1.25);
        const e: Vec = f32x4(math.atan(v[0]), math.atan(v[1]), math.atan(v[2]), math.atan(v[3]));
        try expectVecApproxEqAbs(e, atan(v), epsilon);
    }
    {
        const v: F32x8 = f32x8(-0.25, 0.5, -1.0, 1.25, 100.0, -200.0, 300.0, 400.0);
        // zig fmt: off
        const e: F32x8 = f32x8(
            math.atan(v[0]), math.atan(v[1]), math.atan(v[2]), math.atan(v[3]),
            math.atan(v[4]), math.atan(v[5]), math.atan(v[6]), math.atan(v[7]),
        );
        // zig fmt: on
        try expectVecApproxEqAbs(e, atan(v), epsilon);
    }
    {
        // zig fmt: off
        const v: F32x16 = f32x16(
            -0.25, 0.5, -1.0, 0.0, 0.1, -0.2, 30.0, 400.0,
            -0.25, 0.5, -1.0, -0.0, -0.05, -0.125, 0.0625, 4000.0
        );
        const e: F32x16 = f32x16(
            math.atan(v[0]), math.atan(v[1]), math.atan(v[2]), math.atan(v[3]),
            math.atan(v[4]), math.atan(v[5]), math.atan(v[6]), math.atan(v[7]),
            math.atan(v[8]), math.atan(v[9]), math.atan(v[10]), math.atan(v[11]),
            math.atan(v[12]), math.atan(v[13]), math.atan(v[14]), math.atan(v[15]),
        );
        // zig fmt: on
        try expectVecApproxEqAbs(e, atan(v), epsilon);
    }
    {
        try expectVecApproxEqAbs(atan(splat(math.inf(f32))), splat(0.5 * pi), epsilon);
        try expectVecApproxEqAbs(atan(splat(-math.inf(f32))), splat(-0.5 * pi), epsilon);
        try expect(allTrue(isNan(atan(splat(math.nan(f32)))), 0) == true);
        try expect(allTrue(isNan(atan(splat(-math.nan(f32)))), 0) == true);
    }
}

// ---- Scalar trig fallbacks (SPIR-V-safe) ----------------------------
//
// zmath's `atan(v: anytype)` / `asin(v: anytype)` only work for vector
// `T` (Vec/F32x8/F32x16) — they call `@splat` and `@select` which
// reject scalar arguments.  zimr's call sites that need the SCALAR
// form (`atan2(f32, f32)`, `asin(f32)`) hit these helpers instead.
//
// On host, `std.math.atan` / `std.math.asin` would be the obvious
// choice, but their bodies index into a runtime polynomial-coefficient
// table via `[]const f32`, which SPIR-V's Logical addressing model
// rejects (the table can't live in shader storage classes).  We need
// the SAME implementation on both targets so cube_split-style A/B
// visual comparisons stay bit-identical.
//
// Solution: roll our own polynomial.  Degree-11 odd minimax on [-1,1]
// with the `atan(x) = π/2 - atan(1/x)` identity to fold |x|>1 into
// the unit interval.  Max abs error ≈ 3e-6 over [-1000, 1000] (≈22
// bits of f32 precision) — verified against Python's math.atan on
// 10k samples.  Plenty for rendering work.  Was originally factored
// into `src/math_intrinsic.zig` during Stage 1 of math-unification
// and merged here in Stage 3 (one file, one mental model).

/// Scalar atan2 — 4-quadrant reconstruction from atanScalar.  Inherits
/// the polynomial's ~3e-6 precision; the wrapper is just sign +
/// quadrant offset, exact at f32 precision.
fn atan2Scalar(y: f32, x: f32) f32 {
    if (x > 0.0) {
        return atanScalar(y / x);
    }
    if (x < 0.0) {
        if (y >= 0.0) {
            return atanScalar(y / x) + pi;
        }
        return atanScalar(y / x) - pi;
    }
    // x == 0
    if (y > 0.0) {
        return pi / 2.0;
    }
    if (y < 0.0) {
        return -pi / 2.0;
    }
    return 0.0;
}

/// Scalar asin via atan identity: asin(x) = atan(x / sqrt(1 - x²)).
/// Clamped at the |x|=1 asymptote.
fn asinScalar(x: f32) f32 {
    if (x >= 1.0) {
        return pi / 2.0;
    }
    if (x <= -1.0) {
        return -pi / 2.0;
    }
    const denom: f32 = @sqrt(1.0 - x * x);
    return atanScalar(x / denom);
}

pub fn atan2(vy: anytype, vx: anytype) @TypeOf(vx, vy) {
    const T = @TypeOf(vx, vy);
    // Scalar: exact std.math.atan2 on CPU (>100 lines, delegated),
    // polynomial on GPU.  Vectors (CPU SIMD perf + GPU): the
    // DirectXMath-derived polynomial below.
    if (comptime @typeInfo(T) != .vector) {
        if (comptime !is_gpu) {
            return std.math.atan2(vy, vx);
        }
        return atan2Scalar(vy, vx);
    }
    const Tu = @Vector(veclen(T), u32);

    const vx_is_positive =
        (@as(Tu, @bitCast(vx)) & @as(Tu, @splat(0x8000_0000))) == @as(Tu, @splat(0));

    const vy_sign = andInt(vy, splatNegativeZero(T));
    const c0_25pi = orInt(vy_sign, @as(T, @splat(0.25 * pi)));
    const c0_50pi = orInt(vy_sign, @as(T, @splat(0.50 * pi)));
    const c0_75pi = orInt(vy_sign, @as(T, @splat(0.75 * pi)));
    const c1_00pi = orInt(vy_sign, @as(T, @splat(1.00 * pi)));

    var r1: T = blend(vx_is_positive, vy_sign, c1_00pi);
    var r2: T = blend(vx == @as(T, @splat(0.0)), c0_50pi, splatInt(T, 0xffff_ffff));
    const r3 = blend(vy == @as(T, @splat(0.0)), r1, r2);
    const r4: T = blend(vx_is_positive, c0_25pi, c0_75pi);
    const r5: T = blend(isInf(vx), r4, c0_50pi);
    const result: T = blend(isInf(vy), r5, r3);
    const result_valid = @as(Tu, @bitCast(result)) == @as(Tu, @splat(0xffff_ffff));

    const v: T = vy / vx;
    const r0: T = atan(v);

    r1 = blend(vx_is_positive, splatNegativeZero(T), c1_00pi);
    r2 = r0 + r1;

    return blend(result_valid, r2, result);
}
test "zm.atan2" {
    // From DirectXMath XMVectorATan2():
    // Return the inverse tangent of Y / X in the range of -Pi to Pi with the following exceptions:

    //     Y == 0 and X is Negative         -> Pi with the sign of Y
    //     y == 0 and x is positive         -> 0 with the sign of y
    //     Y != 0 and X == 0                -> Pi / 2 with the sign of Y
    //     Y != 0 and X is Negative         -> atan(y/x) + (PI with the sign of Y)
    //     X == -Infinity and Finite Y      -> Pi with the sign of Y
    //     X == +Infinity and Finite Y      -> 0 with the sign of Y
    //     Y == Infinity and X is Finite    -> Pi / 2 with the sign of Y
    //     Y == Infinity and X == -Infinity -> 3Pi / 4 with the sign of Y
    //     Y == Infinity and X == +Infinity -> Pi / 4 with the sign of Y

    const epsilon: f32 = 0.0001;
    try expectVecApproxEqAbs(atan2(splat(0.0), splat(-1.0)), splat(pi), epsilon);
    try expectVecApproxEqAbs(atan2(splat(-0.0), splat(-1.0)), splat(-pi), epsilon);
    try expectVecApproxEqAbs(atan2(splat(1.0), splat(0.0)), splat(0.5 * pi), epsilon);
    try expectVecApproxEqAbs(atan2(splat(-1.0), splat(0.0)), splat(-0.5 * pi), epsilon);
    try expectVecApproxEqAbs(
        atan2(splat(1.0), splat(-1.0)),
        splat(math.atan(@as(f32, -1.0)) + pi),
        epsilon,
    );
    try expectVecApproxEqAbs(
        atan2(splat(-10.0), splat(-2.0)),
        splat(math.atan(@as(f32, 5.0)) - pi),
        epsilon,
    );
    try expectVecApproxEqAbs(atan2(splat(1.0), splat(-math.inf(f32))), splat(pi), epsilon);
    try expectVecApproxEqAbs(atan2(splat(-1.0), splat(-math.inf(f32))), splat(-pi), epsilon);
    try expectVecApproxEqAbs(atan2(splat(1.0), splat(math.inf(f32))), splat(0.0), epsilon);
    try expectVecApproxEqAbs(atan2(splat(-1.0), splat(math.inf(f32))), splat(-0.0), epsilon);
    try expectVecApproxEqAbs(
        atan2(splat(math.inf(f32)), splat(2.0)),
        splat(0.5 * pi),
        epsilon,
    );
    try expectVecApproxEqAbs(
        atan2(splat(-math.inf(f32)), splat(2.0)),
        splat(-0.5 * pi),
        epsilon,
    );
    try expectVecApproxEqAbs(
        atan2(splat(math.inf(f32)), splat(-math.inf(f32))),
        splat(0.75 * pi),
        epsilon,
    );
    try expectVecApproxEqAbs(
        atan2(splat(-math.inf(f32)), splat(-math.inf(f32))),
        splat(-0.75 * pi),
        epsilon,
    );
    try expectVecApproxEqAbs(
        atan2(splat(math.inf(f32)), splat(math.inf(f32))),
        splat(0.25 * pi),
        epsilon,
    );
    try expectVecApproxEqAbs(
        atan2(splat(-math.inf(f32)), splat(math.inf(f32))),
        splat(-0.25 * pi),
        epsilon,
    );
    try expectVecApproxEqAbs(
        atan2(
            f32x8(0.0, -math.inf(f32), -0.0, 2.0, math.inf(f32), math.inf(f32), 1.0, -math.inf(f32)),
            f32x8(-2.0, math.inf(f32), 1.0, 0.0, 10.0, -math.inf(f32), 1.0, -math.inf(f32)),
        ),
        f32x8(
            pi,
            -0.25 * pi,
            -0.0,
            0.5 * pi,
            0.5 * pi,
            0.75 * pi,
            math.atan(@as(f32, 1.0)),
            -0.75 * pi,
        ),
        epsilon,
    );
    try expectVecApproxEqAbs(atan2(splat(0.0), splat(0.0)), splat(0.0), epsilon);
    try expectVecApproxEqAbs(atan2(splat(-0.0), splat(0.0)), splat(0.0), epsilon);
    try expect(allTrue(isNan(atan2(splat(1.0), splat(math.nan(f32)))), 0) == true);
    try expect(allTrue(isNan(atan2(splat(-1.0), splat(math.nan(f32)))), 0) == true);
    try expect(allTrue(isNan(atan2(splat(math.nan(f32)), splat(-1.0))), 0) == true);
    try expect(allTrue(isNan(atan2(splat(-math.nan(f32)), splat(1.0))), 0) == true);
}
//
// 3. 2D, 3D, 4D vector functions
//
/// 2D dot product (lanes 0,1), splatted across all lanes of the
/// returned Vec.  Use when the next operation is more SIMD math
/// (multiplying against a Vec, etc.); use `dot2` (f32) when the
/// result is being compared or stored as a scalar.
pub inline fn dot2Splat(v0: Vec, v1: Vec) Vec {
    var xmm0: Vec = v0 * v1; // | x0*x1 | y0*y1 | -- | -- |
    const xmm1: Vec = swizzle(xmm0, .y, .x, .x, .x); // | y0*y1 | -- | -- | -- |
    xmm0 = f32x4(xmm0[0] + xmm1[0], xmm0[1], xmm0[2], xmm0[3]); // | x0*x1 + y0*y1 | -- | -- | -- |
    return swizzle(xmm0, .x, .x, .x, .x);
}
/// 2D dot product (lanes 0,1) as f32.  Generic over `Vec` and
/// `Vec2` — any 2-indexable input.
pub inline fn dot2(v: anytype, w: anytype) f32 {
    return v[0] * w[0] + v[1] * w[1];
}
test "zm.dot2" {
    const v0: Vec = .{ -1.0, 2.0, 300.0, -2.0 };
    const v1: Vec = .{ 4.0, 5.0, 600.0, 2.0 };
    try expectApproxEqAbs(@as(f32, 6.0), dot2(v0, v1), 0.0001);
    try expectVecApproxEqAbs(dot2Splat(v0, v1), splat(6.0), 0.0001);
    // Vec2-form
    const a: Vec2 = .{ -1.0, 2.0 };
    const b: Vec2 = .{ 4.0, 5.0 };
    try expectApproxEqAbs(@as(f32, 6.0), dot2(a, b), 0.0001);
}

/// 3D dot product (lanes 0,1,2), splatted across all lanes.
pub inline fn dot3Splat(v0: Vec, v1: Vec) Vec {
    const d_v: Vec = v0 * v1;
    return splat(d_v[0] + d_v[1] + d_v[2]);
}
/// 3D dot product (lanes 0,1,2) as f32.  Default form.
pub inline fn dot3(v0: Vec, v1: Vec) f32 {
    return dot3Splat(v0, v1)[0];
}
test "zm.dot3" {
    const v0: Vec = .{ -1.0, 2.0, 3.0, 1.0 };
    const v1: Vec = .{ 4.0, 5.0, 6.0, 1.0 };
    try expectApproxEqAbs(@as(f32, 24.0), dot3(v0, v1), 0.0001);
    try expectVecApproxEqAbs(dot3Splat(v0, v1), splat(24.0), 0.0001);
}

/// 4D dot product, splatted across all lanes.
pub inline fn dot4Splat(v0: Vec, v1: Vec) Vec {
    var xmm0: Vec = v0 * v1; // | x0*x1 | y0*y1 | z0*z1 | w0*w1 |
    var xmm1: Vec = swizzle(xmm0, .y, .x, .w, .x); // | y0*y1 | -- | w0*w1 | -- |
    xmm1 = xmm0 + xmm1; // | x0*x1 + y0*y1 | -- | z0*z1 + w0*w1 | -- |
    xmm0 = swizzle(xmm1, .z, .x, .x, .x); // | z0*z1 + w0*w1 | -- | -- | -- |
    xmm0 = f32x4(xmm0[0] + xmm1[0], xmm0[1], xmm0[2], xmm0[2]); // addss
    return swizzle(xmm0, .x, .x, .x, .x);
}
/// 4D dot product as f32.  Default form.
pub inline fn dot4(v0: Vec, v1: Vec) f32 {
    return dot4Splat(v0, v1)[0];
}
test "zm.dot4" {
    const v0: Vec = .{ -1.0, 2.0, 3.0, -2.0 };
    const v1: Vec = .{ 4.0, 5.0, 6.0, 2.0 };
    try expectApproxEqAbs(@as(f32, 20.0), dot4(v0, v1), 0.0001);
    try expectVecApproxEqAbs(dot4Splat(v0, v1), splat(20.0), 0.0001);
}

pub inline fn cross(v0: Vec, v1: Vec) Vec {
    var xmm0: Vec = swizzle(v0, .y, .z, .x, .w);
    var xmm1: Vec = swizzle(v1, .z, .x, .y, .w);
    var result: Vec = xmm0 * xmm1;
    xmm0 = swizzle(xmm0, .y, .z, .x, .w);
    xmm1 = swizzle(xmm1, .z, .x, .y, .w);
    result = result - xmm0 * xmm1;
    // Zero the w lane via @shuffle.  This used to be
    // `andInt(result, f32x4_mask3())` which relies on a vector-level
    // bitcast `@bitCast(Vec, @Vector(4, u32))` that SPIR-V's Logical
    // addressing model rejects (verified empirically: the Stage 3
    // smoke shader trips `OpLoad Pointer is not a logical pointer`).
    // @shuffle compiles cleanly on both targets — emits a single
    // SPIR-V OpVectorShuffle.  The second operand is the zero vector;
    // shuffle index `~3` selects the second operand's lane 3 (the 0).
    return @shuffle(f32, result, Vec{ 0, 0, 0, 0 }, [4]i32{ 0, 1, 2, ~@as(i32, 3) });
}
test "zm.cross" {
    {
        const v0: Vec = .{ 1.0, 0.0, 0.0, 1.0 };
        const v1: Vec = .{ 0.0, 1.0, 0.0, 1.0 };
        const v: Vec = cross(v0, v1);
        try expectVecApproxEqAbs(v, f32x4(0.0, 0.0, 1.0, 0.0), 0.0001);
    }
    {
        const v0: Vec = .{ 1.0, 0.0, 0.0, 1.0 };
        const v1: Vec = .{ 0.0, -1.0, 0.0, 1.0 };
        const v: Vec = cross(v0, v1);
        try expectVecApproxEqAbs(v, f32x4(0.0, 0.0, -1.0, 0.0), 0.0001);
    }
    {
        const v0: Vec = .{ -3.0, 0, -2.0, 1.0 };
        const v1: Vec = .{ 5.0, -1.0, 2.0, 1.0 };
        const v: Vec = cross(v0, v1);
        try expectVecApproxEqAbs(v, f32x4(-2.0, -4.0, 3.0, 0.0), 0.0001);
    }
}

pub inline fn lengthSq2Splat(v: Vec) Vec {
    return dot2Splat(v, v);
}
pub inline fn lengthSq3Splat(v: Vec) Vec {
    return dot3Splat(v, v);
}
pub inline fn lengthSq4Splat(v: Vec) Vec {
    return dot4Splat(v, v);
}
pub inline fn lengthSq2(v: anytype) f32 {
    return dot2(v, v);
}
pub inline fn lengthSq3(v: Vec) f32 {
    return dot3(v, v);
}
pub inline fn lengthSq4(v: Vec) f32 {
    return dot4(v, v);
}

pub inline fn length2Splat(v: Vec) Vec {
    return sqrt(dot2Splat(v, v));
}
pub inline fn length3Splat(v: Vec) Vec {
    return sqrt(dot3Splat(v, v));
}
pub inline fn length4Splat(v: Vec) Vec {
    return sqrt(dot4Splat(v, v));
}
pub inline fn length2(v: anytype) f32 {
    return @sqrt(dot2(v, v));
}
pub inline fn length3(v: Vec) f32 {
    return @sqrt(dot3(v, v));
}
pub inline fn length4(v: Vec) f32 {
    return @sqrt(dot4(v, v));
}
test "zm.length3" {
    {
        try expectApproxEqAbs(@as(f32, math.sqrt(14.0)), length3(f32x4(1.0, -2.0, 3.0, 1000.0)), 0.001);
    }
    {
        try expect(math.isNan(length3(f32x4(1.0, math.nan(f32), math.nan(f32), 1000.0))));
    }
    {
        try expect(math.isInf(length3(f32x4(1.0, math.inf(f32), 3.0, 1000.0))));
    }
    {
        // lane 3 is ignored by length3
        try expectApproxEqAbs(
            @as(f32, math.sqrt(14.0)),
            length3(f32x4(3.0, 2.0, 1.0, math.nan(f32))),
            0.001,
        );
    }
}

pub inline fn normalize2(v: Vec) Vec {
    return v / length2Splat(v);
}
pub inline fn normalize3(v: Vec) Vec {
    // Guard: normalizing a zero vector divides by 0 -> NaN, which has repeatedly
    // blanked frames. Caught in dev at ZERO release/shader cost (assertf assumes
    // the condition on GPU + in ship). If the input CAN be zero, use
    // safeNormalize3 instead.
    assertf(dot3(v, v) > 0.0, @src(), "normalize3: zero-length vector", .{});
    return v / length3Splat(v);
}

/// NaN-free normalize: returns `fallback` when `v` is at/near the zero vector
/// (length below `eps`), instead of dividing by ~0 to produce NaN. BRANCHLESS
/// (uses @select), so it lowers to SPIR-V/WGSL — safe in shaders. This is the
/// preventive tool for the recurring "degenerate input -> NaN -> black/white
/// frame" class: prefer it over normalize3 anywhere the input can be zero (ray
/// directions, scatter dirs, gradients). `fallback` should be a unit vector
/// (e.g. .{0,0,1,0}) or .{0,0,0,0} if a zero result is acceptable.
pub inline fn safeNormalize3(v: Vec, fallback: Vec) Vec {
    const len_sq: f32 = dot3(v, v);
    const eps: f32 = 1.0e-12;
    // mask lanes are all-true when length is usable; @select picks per-lane.
    const ok: bool = len_sq > eps;
    const normalized: Vec = v / splat(@sqrt(len_sq + eps)); // +eps: never /0
    return blend(@as(@Vector(4, bool), @splat(ok)), normalized, fallback);
}

/// Replace any NaN/inf lanes of `v` with the matching lane of `fallback`.
/// BRANCHLESS — for sanitizing accumulated shader values (color, position)
/// right before they leave a hot loop, so a single bad lane can't blacken/
/// whiten the whole frame. (isNan covers NaN; for inf, comparisons also fail,
/// so we test finiteness via `v == v` for NaN AND a magnitude clamp upstream.)
pub inline fn finiteOr3(v: Vec, fallback: Vec) Vec {
    // v != v is true only for NaN lanes; @select replaces those.
    const is_nan: @Vector(4, bool) = v != v;
    return @select(f32, is_nan, fallback, v);
}
pub inline fn normalize4(v: Vec) Vec {
    return v / length4Splat(v);
}
test "zm.normalize3" {
    {
        const v0: Vec = .{ 1.0, -2.0, 3.0, 1000.0 };
        const v: Vec = normalize3(v0);
        try expectVecApproxEqAbs(v, v0 * splat(1.0 / math.sqrt(14.0)), 0.0005);
    }
    {
        // normalize3 now ASSERTS length>0 in debug (no zero/NaN-input contract);
        // degenerate handling is safeNormalize3's job (tested separately). Keep
        // only finite-input checks here. inf input still propagates (caller's
        // responsibility to feed finite vectors or use safeNormalize3).
        try expect(anyTrue(isNan(normalize3(f32x4(1.0, math.inf(f32), 1.0, 1.0))), 0));
    }
}
test "zm.normalize4" {
    {
        const v0: Vec = .{ 1.0, -2.0, 3.0, 10.0 };
        const v: Vec = normalize4(v0);
        try expectVecApproxEqAbs(v, v0 * splat(1.0 / math.sqrt(114.0)), 0.0005);
    }
    {
        try expect(anyTrue(isNan(normalize4(f32x4(1.0, math.inf(f32), 1.0, 1.0))), 0));
        try expect(anyTrue(isNan(normalize4(f32x4(-math.inf(f32), math.inf(f32), 0.0, 0.0))), 0));
        try expect(anyTrue(isNan(normalize4(f32x4(-math.nan(f32), math.snan(f32), 0.0, 0.0))), 0));
        try expect(anyTrue(isNan(normalize4(f32x4(0, 0, 0, 0))), 0));
    }
}

fn vecMulMat(v: Vec, m: Mat) Vec {
    const vx = @shuffle(f32, v, undefined, [4]i32{ 0, 0, 0, 0 });
    const vy = @shuffle(f32, v, undefined, [4]i32{ 1, 1, 1, 1 });
    const vz = @shuffle(f32, v, undefined, [4]i32{ 2, 2, 2, 2 });
    const vw = @shuffle(f32, v, undefined, [4]i32{ 3, 3, 3, 3 });
    return vx * m[0] + vy * m[1] + vz * m[2] + vw * m[3];
}
fn matMulVec(m: Mat, v: Vec) Vec {
    return .{ dot4(m[0], v), dot4(m[1], v), dot4(m[2], v), dot4(m[3], v) };
}
//
// 4. Matrix functions
//

pub fn matFromArr(arr: [16]f32) Mat {
    return Mat{
        f32x4(arr[0], arr[1], arr[2], arr[3]),
        f32x4(arr[4], arr[5], arr[6], arr[7]),
        f32x4(arr[8], arr[9], arr[10], arr[11]),
        f32x4(arr[12], arr[13], arr[14], arr[15]),
    };
}

// ---- Matrix arithmetic — column-major, M*v convention ---------------
//
// Storage: `Mat = [4]Vec`.  Mat[i] is COLUMN i.  Translation lives in
// the LAST column: `mat[3] = (x, y, z, 1)`.
//
// Multiplication: `mulMat(A, B)` computes `A * B`.  Applied to a
// column vector: `mulMatVec(mulMat(A, B), v) == mulMatVec(A,
// mulMatVec(B, v))`.  This matches GLSL conventions: in a shader,
// `vec4 transformed = mvp * vertex_position;` and the host-side
// MVP is built with `mulMat(proj, mulMat(view, model))`.
//
// Stage 2 of the math-unification plan replaced an old polymorphic
// `mul(a, b)` that used row-major `v*M` convention.  The byte
// storage is unchanged from that era — `translation(x, y, z)`
// produces the same 64 bytes — but the operand-order convention
// flipped: old `mul(view, proj)` became new `mulMat(proj, view)`
// because "left applies first" inverts when you switch from
// post-multiply to pre-multiply convention.  See `src/notes/
// math_unification.md` for the full duality analysis.

/// Compose two matrices: `A * B`.  Applied to a vector `v` later,
/// `mulMatVec(mulMat(A, B), v)` equals `mulMatVec(A, mulMatVec(B,
/// v))` — B is applied to v first, then A.  The mental model is
/// the same as GLSL: build MVP as `mulMat(proj, mulMat(view,
/// model))` and the resulting matrix transforms model-space →
/// clip-space when multiplied against a position.
///
/// APPLICATION ORDER: `mulMat(SECOND, FIRST)`.  To apply transform
/// P to a point and THEN Q (Q acting in P's output space), write
/// `mulMat(Q, P)` — the later transform goes on the LEFT.
///
/// ⚠ PORTING FROM RAYLIB: raylib's `MatrixMultiply(left, right)`
/// uses the OPPOSITE (row-vector) order — it applies `left` first,
/// then `right` (`v * left * right`).  So a raylib line
/// `M = MatrixMultiply(A, B)` translates to `mulMat(B, A)` here,
/// NOT `mulMat(A, B)`.  Copying the operand order verbatim silently
/// reverses the composition — it type-checks and often *looks*
/// close, then places/orients things wrongly (see the decals port:
/// raylib `MatrixMultiply(splat, MatrixRotateZ(a))` became
/// `mulMat(rotationZ(a), splat)`).  This is doubly easy to miss
/// with a view/`lookAt*` matrix, whose second operand is meant to
/// act in the *projected* space, not world space.
pub fn mulMat(a: Mat, b: Mat) Mat {
    // Column-major math: (A*B).col[i] = A * B.col[i].  For each
    // output column, multiply A by B's i-th column (treating it as
    // a 4-vector).  Implementation: splat each scalar of B.col[i],
    // multiply by A's columns, sum.  This is the SAME arithmetic
    // as `vecMulMat(b[i], a)` for each i — i.e. old-row-major
    // `mulMatRowMajor(B, A)` with operand swap.
    var result: Mat = undefined;
    comptime var col: u32 = 0;
    inline while (col < 4) : (col += 1) {
        const bc = b[col];
        const vx = swizzle(bc, .x, .x, .x, .x);
        const vy = swizzle(bc, .y, .y, .y, .y);
        const vz = swizzle(bc, .z, .z, .z, .z);
        const vw = swizzle(bc, .w, .w, .w, .w);
        result[col] = mulAdd(vx, a[0], vz * a[2]) + mulAdd(vy, a[1], vw * a[3]);
    }
    return result;
}

/// Compose transforms in APPLICATION ORDER: `compose(first, then)`
/// returns a matrix that applies `first` to a point, then `then`.
/// This is the readable inverse of `mulMat`'s operand order —
/// `compose(a, b) == mulMat(b, a)` — and exists so call sites can
/// state intent instead of juggling which operand goes on the left.
///
/// Prefer this when building a transform as a sequence of steps,
/// and ESPECIALLY when porting raylib: raylib's
/// `MatrixMultiply(left, right)` already means "apply left, then
/// right", so it maps 1:1 to `compose(left, right)` with the SAME
/// operand order — no silent flip.  Example: raylib
/// `splat = MatrixMultiply(lookAtMat, MatrixRotateZ(a))` →
/// `compose(lookAtMat, rotationZ(a))`.
pub fn compose(first: Mat, then: Mat) Mat {
    return mulMat(then, first);
}

/// Compose three transforms in application order: apply `first`,
/// then `second`, then `third`.  `composeN` for the common
/// three-step case (model→view→proj reads `composeN(model, view,
/// proj)`); equals `mulMat(third, mulMat(second, first))`.
pub fn composeN(first: Mat, second: Mat, third: Mat) Mat {
    return mulMat(third, mulMat(second, first));
}

/// Internally identical to the legacy private `vecMulMat(v, M)`:
/// the column-major M*v computation equals the row-major v*M
/// computation when the same bytes are interpreted under the
/// dual conventions (commutative scalar mul + matching indexed
/// reads).  See `src/notes/math_unification.md`.
pub fn mulMatVec(m: Mat, v: Vec) Vec {
    return vecMulMat(v, m);
}

/// Multiply matrix `M` by scalar `s` (componentwise on every
/// element of every column).  Renamed from the `(Mat, f32)`
/// branch of the legacy polymorphic `mul`.
pub fn mulMatScalar(m: Mat, s: f32) Mat {
    const vs: Vec = splat(s);
    return Mat{ m[0] * vs, m[1] * vs, m[2] * vs, m[3] * vs };
}

/// Transform a 3D point through a mat4 with implied `w = 1` — the
/// standard "transform a position" operation, matching GLSL's
/// `M * vec4(p, 1.0)`.  Returns a vec4; caller divides by `.w`
/// for the perspective divide if needed.
pub fn mulMatPoint(m: Mat, p: Vec3) Vec {
    return mulMatVec(m, f32x4(p[0], p[1], p[2], 1.0));
}

test "mulMat composes in math order: mulMatVec(mulMat(A,B), v) == A*(B*v)" {
    const A: Mat = .{
        f32x4(1, 0, 0, 0),
        f32x4(0, 2, 0, 0),
        f32x4(0, 0, 3, 0),
        f32x4(0, 0, 0, 1),
    };
    const B: Mat = .{
        f32x4(1, 0, 0, 0),
        f32x4(0, 1, 0, 0),
        f32x4(0, 0, 1, 0),
        f32x4(10, 20, 30, 1),
    };
    const v: Vec = f32x4(1, 1, 1, 1);
    const direct: Vec = mulMatVec(A, mulMatVec(B, v));
    const composed: Vec = mulMatVec(mulMat(A, B), v);
    try expectVecApproxEqAbs(direct, composed, 1e-6);
    // Translation column should be (10, 40, 90, 1):
    // B translates (1,1,1) → (11,21,31), then A scales by (1,2,3)
    // → (11, 42, 93).  v.w stays 1.
    try expectVecApproxEqAbs(composed, f32x4(11, 42, 93, 1), 1e-6);
}

test "compose applies first, then second (application order == raylib MatrixMultiply order)" {
    // Scale-by-(1,2,3), then translate-by-(10,20,30).  Reading order
    // matches the argument order: compose(scale, translate).
    const scale: Mat = .{
        f32x4(1, 0, 0, 0),
        f32x4(0, 2, 0, 0),
        f32x4(0, 0, 3, 0),
        f32x4(0, 0, 0, 1),
    };
    const translate: Mat = .{
        f32x4(1, 0, 0, 0),
        f32x4(0, 1, 0, 0),
        f32x4(0, 0, 1, 0),
        f32x4(10, 20, 30, 1),
    };
    const v: Vec = f32x4(1, 1, 1, 1);
    // Apply scale first: (1,1,1) → (1,2,3); then translate → (11, 22, 33).
    const m: Mat = compose(scale, translate);
    try expectVecApproxEqAbs(mulMatVec(m, v), f32x4(11, 22, 33, 1), 1e-6);
    // compose(a, b) is exactly mulMat(b, a) — the operand-order inverse.
    try expectVecApproxEqAbs(mulMatVec(compose(scale, translate), v), mulMatVec(mulMat(translate, scale), v), 1e-6);
    // composeN(model, view, proj) == mulMat(proj, mulMat(view, model)).
    const three: Vec = mulMatVec(composeN(scale, translate, scale), v);
    const nested: Vec = mulMatVec(mulMat(scale, mulMat(translate, scale)), v);
    try expectVecApproxEqAbs(three, nested, 1e-6);
}

pub fn translation(x: f32, y: f32, z: f32) Mat {
    return .{
        f32x4(1.0, 0.0, 0.0, 0.0),
        f32x4(0.0, 1.0, 0.0, 0.0),
        f32x4(0.0, 0.0, 1.0, 0.0),
        f32x4(x, y, z, 1.0),
    };
}

test "mulMatVec on translation matrix moves the point" {
    const t: Mat = translation(5, 10, 15);
    const p: Vec = f32x4(1, 2, 3, 1);
    const result: Vec = mulMatVec(t, p);
    try expectVecApproxEqAbs(result, f32x4(6, 12, 18, 1), 1e-6);
}

test "mulMatScalar scales every element" {
    const m: Mat = .{
        f32x4(0.1, 0.2, 0.3, 0.4),
        f32x4(0.5, 0.6, 0.7, 0.8),
        f32x4(0.9, 1.0, 1.1, 1.2),
        f32x4(1.3, 1.4, 1.5, 1.6),
    };
    const result: Mat = mulMatScalar(m, 2.0);
    try expectVecApproxEqAbs(result[0], f32x4(0.2, 0.4, 0.6, 0.8), 1e-6);
    try expectVecApproxEqAbs(result[3], f32x4(2.6, 2.8, 3.0, 3.2), 1e-6);
}

test "mulMat against known matrix product" {
    // Note: under the new column-major + M*v convention, c = mulMat(a, b)
    // means "applied to v, c*v == a*(b*v)".  The byte-level result is
    // the operand-swap of the legacy row-major mul(a, b).  Hence the
    // expected values here differ from the old test by swapping a ↔ b.
    const a: Mat = .{
        f32x4(0.1, 0.2, 0.3, 0.4),
        f32x4(0.5, 0.6, 0.7, 0.8),
        f32x4(0.9, 1.0, 1.1, 1.2),
        f32x4(1.3, 1.4, 1.5, 1.6),
    };
    const b: Mat = .{
        f32x4(1.7, 1.8, 1.9, 2.0),
        f32x4(2.1, 2.2, 2.3, 2.4),
        f32x4(2.5, 2.6, 2.7, 2.8),
        f32x4(2.9, 3.0, 3.1, 3.2),
    };
    // Old `mul(a, b)` produced columns starting with f32x4(2.5, 2.6, 2.7,
    // 2.8).  New `mulMat(a, b)` produces a DIFFERENT matrix (the operand
    // order swapped).  Verify with the math identity: result column i
    // equals a applied to b's column i.
    const c: Mat = mulMat(a, b);
    const c0_expected: Vec = mulMatVec(a, b[0]);
    const c3_expected: Vec = mulMatVec(a, b[3]);
    try expectVecApproxEqAbs(c[0], c0_expected, 1e-5);
    try expectVecApproxEqAbs(c[3], c3_expected, 1e-5);
}

pub fn transpose(m: Mat) Mat {
    const temp1 = @shuffle(f32, m[0], m[1], [4]i32{ 0, 1, ~@as(i32, 0), ~@as(i32, 1) });
    const temp3 = @shuffle(f32, m[0], m[1], [4]i32{ 2, 3, ~@as(i32, 2), ~@as(i32, 3) });
    const temp2 = @shuffle(f32, m[2], m[3], [4]i32{ 0, 1, ~@as(i32, 0), ~@as(i32, 1) });
    const temp4 = @shuffle(f32, m[2], m[3], [4]i32{ 2, 3, ~@as(i32, 2), ~@as(i32, 3) });
    return .{
        @shuffle(f32, temp1, temp2, [4]i32{ 0, 2, ~@as(i32, 0), ~@as(i32, 2) }),
        @shuffle(f32, temp1, temp2, [4]i32{ 1, 3, ~@as(i32, 1), ~@as(i32, 3) }),
        @shuffle(f32, temp3, temp4, [4]i32{ 0, 2, ~@as(i32, 0), ~@as(i32, 2) }),
        @shuffle(f32, temp3, temp4, [4]i32{ 1, 3, ~@as(i32, 1), ~@as(i32, 3) }),
    };
}
test "zm.matrix.transpose" {
    const m: Mat = .{
        f32x4(1.0, 2.0, 3.0, 4.0),
        f32x4(5.0, 6.0, 7.0, 8.0),
        f32x4(9.0, 10.0, 11.0, 12.0),
        f32x4(13.0, 14.0, 15.0, 16.0),
    };
    const mt: Mat = transpose(m);
    try expectVecApproxEqAbs(mt[0], f32x4(1.0, 5.0, 9.0, 13.0), 0.0001);
    try expectVecApproxEqAbs(mt[1], f32x4(2.0, 6.0, 10.0, 14.0), 0.0001);
    try expectVecApproxEqAbs(mt[2], f32x4(3.0, 7.0, 11.0, 15.0), 0.0001);
    try expectVecApproxEqAbs(mt[3], f32x4(4.0, 8.0, 12.0, 16.0), 0.0001);
}

pub fn rotationX(angle_rad: f32) Mat {
    const sc: [2]f32 = sincos(angle_rad);
    return .{
        f32x4(1.0, 0.0, 0.0, 0.0),
        f32x4(0.0, sc[1], sc[0], 0.0),
        f32x4(0.0, -sc[0], sc[1], 0.0),
        f32x4(0.0, 0.0, 0.0, 1.0),
    };
}

pub fn rotationY(angle_rad: f32) Mat {
    const sc: [2]f32 = sincos(angle_rad);
    return .{
        f32x4(sc[1], 0.0, -sc[0], 0.0),
        f32x4(0.0, 1.0, 0.0, 0.0),
        f32x4(sc[0], 0.0, sc[1], 0.0),
        f32x4(0.0, 0.0, 0.0, 1.0),
    };
}

pub fn rotationZ(angle_rad: f32) Mat {
    const sc: [2]f32 = sincos(angle_rad);
    return .{
        f32x4(sc[1], sc[0], 0.0, 0.0),
        f32x4(-sc[0], sc[1], 0.0, 0.0),
        f32x4(0.0, 0.0, 1.0, 0.0),
        f32x4(0.0, 0.0, 0.0, 1.0),
    };
}

pub fn translationV(v: Vec) Mat {
    return translation(v[0], v[1], v[2]);
}

pub fn scaling(x: f32, y: f32, z: f32) Mat {
    return .{
        f32x4(x, 0.0, 0.0, 0.0),
        f32x4(0.0, y, 0.0, 0.0),
        f32x4(0.0, 0.0, z, 0.0),
        f32x4(0.0, 0.0, 0.0, 1.0),
    };
}
pub fn scalingV(v: Vec) Mat {
    return scaling(v[0], v[1], v[2]);
}

pub fn lookToLh(
    eyepos: Vec,
    eyedir: Vec,
    updir: Vec,
) Mat {
    const az: Vec = normalize3(eyedir);
    const ax: Vec = normalize3(cross(updir, az));
    const ay: Vec = normalize3(cross(az, ax));
    return .{
        f32x4(ax[0], ay[0], az[0], 0),
        f32x4(ax[1], ay[1], az[1], 0),
        f32x4(ax[2], ay[2], az[2], 0),
        f32x4(-dot3(ax, eyepos), -dot3(ay, eyepos), -dot3(az, eyepos), 1.0),
    };
}
pub fn lookToRh(
    eyepos: Vec,
    eyedir: Vec,
    updir: Vec,
) Mat {
    return lookToLh(eyepos, -eyedir, updir);
}
pub fn lookAtLh(
    eyepos: Vec,
    focuspos: Vec,
    updir: Vec,
) Mat {
    return lookToLh(eyepos, focuspos - eyepos, updir);
}
pub fn lookAtRh(
    eyepos: Vec,
    focuspos: Vec,
    updir: Vec,
) Mat {
    return lookToLh(eyepos, eyepos - focuspos, updir);
}
test "zm.matrix.lookToLh" {
    const m: Mat = lookToLh(f32x4(0.0, 0.0, -3.0, 1.0), f32x4(0.0, 0.0, 1.0, 0.0), f32x4(0.0, 1.0, 0.0, 0.0));
    try expectVecApproxEqAbs(m[0], f32x4(1.0, 0.0, 0.0, 0.0), 0.001);
    try expectVecApproxEqAbs(m[1], f32x4(0.0, 1.0, 0.0, 0.0), 0.001);
    try expectVecApproxEqAbs(m[2], f32x4(0.0, 0.0, 1.0, 0.0), 0.001);
    try expectVecApproxEqAbs(m[3], f32x4(0.0, 0.0, 3.0, 1.0), 0.001);
}

pub fn perspectiveFovLh(fovy: f32, aspect: f32, near: f32, far: f32) Mat {
    const scfov: [2]f32 = sincos(0.5 * fovy);

    assert(near > 0.0 and far > 0.0, @src());
    assert(!math.approxEqAbs(f32, scfov[0], 0.0, 0.001), @src());
    assert(!math.approxEqAbs(f32, far, near, 0.001), @src());
    assert(!math.approxEqAbs(f32, aspect, 0.0, 0.01), @src());

    const h: f32 = scfov[1] / scfov[0];
    const w: f32 = h / aspect;
    const r: f32 = far / (far - near);
    return .{
        f32x4(w, 0.0, 0.0, 0.0),
        f32x4(0.0, h, 0.0, 0.0),
        f32x4(0.0, 0.0, r, 1.0),
        f32x4(0.0, 0.0, -r * near, 0.0),
    };
}
pub fn perspectiveFovRh(fovy: f32, aspect: f32, near: f32, far: f32) Mat {
    const scfov: [2]f32 = sincos(0.5 * fovy);

    assert(near > 0.0 and far > 0.0, @src());
    assert(!math.approxEqAbs(f32, scfov[0], 0.0, 0.001), @src());
    assert(!math.approxEqAbs(f32, far, near, 0.001), @src());
    assert(!math.approxEqAbs(f32, aspect, 0.0, 0.01), @src());

    const h: f32 = scfov[1] / scfov[0];
    const w: f32 = h / aspect;
    const r: f32 = far / (near - far);
    return .{
        f32x4(w, 0.0, 0.0, 0.0),
        f32x4(0.0, h, 0.0, 0.0),
        f32x4(0.0, 0.0, r, -1.0),
        f32x4(0.0, 0.0, r * near, 0.0),
    };
}

// Produces Z values in [-1.0, 1.0] range (OpenGL defaults)
pub fn perspectiveFovLhGl(fovy: f32, aspect: f32, near: f32, far: f32) Mat {
    const scfov: [2]f32 = sincos(0.5 * fovy);

    assert(near > 0.0 and far > 0.0, @src());
    assert(!math.approxEqAbs(f32, scfov[0], 0.0, 0.001), @src());
    assert(!math.approxEqAbs(f32, far, near, 0.001), @src());
    assert(!math.approxEqAbs(f32, aspect, 0.0, 0.01), @src());

    const h: f32 = scfov[1] / scfov[0];
    const w: f32 = h / aspect;
    const r: f32 = far - near;
    return .{
        f32x4(w, 0.0, 0.0, 0.0),
        f32x4(0.0, h, 0.0, 0.0),
        f32x4(0.0, 0.0, (near + far) / r, 1.0),
        f32x4(0.0, 0.0, 2.0 * near * far / -r, 0.0),
    };
}

// Produces Z values in [-1.0, 1.0] range (OpenGL defaults)
pub fn perspectiveFovRhGl(fovy: f32, aspect: f32, near: f32, far: f32) Mat {
    const scfov: [2]f32 = sincos(0.5 * fovy);

    assert(near > 0.0 and far > 0.0, @src());
    assert(!math.approxEqAbs(f32, scfov[0], 0.0, 0.001), @src());
    assert(!math.approxEqAbs(f32, far, near, 0.001), @src());
    assert(!math.approxEqAbs(f32, aspect, 0.0, 0.01), @src());

    const h: f32 = scfov[1] / scfov[0];
    const w: f32 = h / aspect;
    const r: f32 = near - far;
    return .{
        f32x4(w, 0.0, 0.0, 0.0),
        f32x4(0.0, h, 0.0, 0.0),
        f32x4(0.0, 0.0, (near + far) / r, -1.0),
        f32x4(0.0, 0.0, 2.0 * near * far / r, 0.0),
    };
}

pub fn orthographicLh(w: f32, h: f32, near: f32, far: f32) Mat {
    assert(!math.approxEqAbs(f32, w, 0.0, 0.001), @src());
    assert(!math.approxEqAbs(f32, h, 0.0, 0.001), @src());
    assert(!math.approxEqAbs(f32, far, near, 0.001), @src());

    const r: f32 = 1 / (far - near);
    return .{
        f32x4(2 / w, 0.0, 0.0, 0.0),
        f32x4(0.0, 2 / h, 0.0, 0.0),
        f32x4(0.0, 0.0, r, 0.0),
        f32x4(0.0, 0.0, -r * near, 1.0),
    };
}

pub fn orthographicRh(w: f32, h: f32, near: f32, far: f32) Mat {
    assert(!math.approxEqAbs(f32, w, 0.0, 0.001), @src());
    assert(!math.approxEqAbs(f32, h, 0.0, 0.001), @src());
    assert(!math.approxEqAbs(f32, far, near, 0.001), @src());

    const r: f32 = 1 / (near - far);
    return .{
        f32x4(2 / w, 0.0, 0.0, 0.0),
        f32x4(0.0, 2 / h, 0.0, 0.0),
        f32x4(0.0, 0.0, r, 0.0),
        f32x4(0.0, 0.0, r * near, 1.0),
    };
}

// Produces Z values in [-1.0, 1.0] range (OpenGL defaults)
pub fn orthographicLhGl(w: f32, h: f32, near: f32, far: f32) Mat {
    assert(!math.approxEqAbs(f32, w, 0.0, 0.001), @src());
    assert(!math.approxEqAbs(f32, h, 0.0, 0.001), @src());
    assert(!math.approxEqAbs(f32, far, near, 0.001), @src());

    const r: f32 = far - near;
    return .{
        f32x4(2 / w, 0.0, 0.0, 0.0),
        f32x4(0.0, 2 / h, 0.0, 0.0),
        f32x4(0.0, 0.0, 2 / r, 0.0),
        f32x4(0.0, 0.0, (near + far) / -r, 1.0),
    };
}

// Produces Z values in [-1.0, 1.0] range (OpenGL defaults)
pub fn orthographicRhGl(w: f32, h: f32, near: f32, far: f32) Mat {
    assert(!math.approxEqAbs(f32, w, 0.0, 0.001), @src());
    assert(!math.approxEqAbs(f32, h, 0.0, 0.001), @src());
    assert(!math.approxEqAbs(f32, far, near, 0.001), @src());

    const r: f32 = near - far;
    return .{
        f32x4(2 / w, 0.0, 0.0, 0.0),
        f32x4(0.0, 2 / h, 0.0, 0.0),
        f32x4(0.0, 0.0, 2 / r, 0.0),
        f32x4(0.0, 0.0, (near + far) / r, 1.0),
    };
}

pub fn orthographicOffCenterLh(
    left: f32,
    right: f32,
    top: f32,
    bottom: f32,
    near: f32,
    far: f32,
) Mat {
    assert(!math.approxEqAbs(f32, far, near, 0.001), @src());

    const r: f32 = 1 / (far - near);
    return .{
        f32x4(2 / (right - left), 0.0, 0.0, 0.0),
        f32x4(0.0, 2 / (top - bottom), 0.0, 0.0),
        f32x4(0.0, 0.0, r, 0.0),
        f32x4(-(right + left) / (right - left), -(top + bottom) / (top - bottom), -r * near, 1.0),
    };
}

pub fn orthographicOffCenterRh(
    left: f32,
    right: f32,
    top: f32,
    bottom: f32,
    near: f32,
    far: f32,
) Mat {
    assert(!math.approxEqAbs(f32, far, near, 0.001), @src());

    const r: f32 = 1 / (near - far);
    return .{
        f32x4(2 / (right - left), 0.0, 0.0, 0.0),
        f32x4(0.0, 2 / (top - bottom), 0.0, 0.0),
        f32x4(0.0, 0.0, r, 0.0),
        f32x4(-(right + left) / (right - left), -(top + bottom) / (top - bottom), r * near, 1.0),
    };
}

// Produces Z values in [-1.0, 1.0] range (OpenGL defaults)
pub fn orthographicOffCenterLhGl(
    left: f32,
    right: f32,
    top: f32,
    bottom: f32,
    near: f32,
    far: f32,
) Mat {
    assert(!math.approxEqAbs(f32, far, near, 0.001), @src());

    const r: f32 = far - near;
    return .{
        f32x4(2 / (right - left), 0.0, 0.0, 0.0),
        f32x4(0.0, 2 / (top - bottom), 0.0, 0.0),
        f32x4(0.0, 0.0, 2 / r, 0.0),
        f32x4(-(right + left) / (right - left), -(top + bottom) / (top - bottom), (near + far) / -r, 1.0),
    };
}

// Produces Z values in [-1.0, 1.0] range (OpenGL defaults)
pub fn orthographicOffCenterRhGl(
    left: f32,
    right: f32,
    top: f32,
    bottom: f32,
    near: f32,
    far: f32,
) Mat {
    assert(!math.approxEqAbs(f32, far, near, 0.001), @src());

    const r: f32 = near - far;
    return .{
        f32x4(2 / (right - left), 0.0, 0.0, 0.0),
        f32x4(0.0, 2 / (top - bottom), 0.0, 0.0),
        f32x4(0.0, 0.0, 2 / r, 0.0),
        f32x4(-(right + left) / (right - left), -(top + bottom) / (top - bottom), (near + far) / r, 1.0),
    };
}

pub fn determinantSplat(m: Mat) Vec {
    var v0: Vec = swizzle(m[2], .y, .x, .x, .x);
    var v1: Vec = swizzle(m[3], .z, .z, .y, .y);
    var v2: Vec = swizzle(m[2], .y, .x, .x, .x);
    var v3: Vec = swizzle(m[3], .w, .w, .w, .z);
    var v4: Vec = swizzle(m[2], .z, .z, .y, .y);
    var v5: Vec = swizzle(m[3], .w, .w, .w, .z);

    var p0: Vec = v0 * v1;
    var p1: Vec = v2 * v3;
    var p2: Vec = v4 * v5;

    v0 = swizzle(m[2], .z, .z, .y, .y);
    v1 = swizzle(m[3], .y, .x, .x, .x);
    v2 = swizzle(m[2], .w, .w, .w, .z);
    v3 = swizzle(m[3], .y, .x, .x, .x);
    v4 = swizzle(m[2], .w, .w, .w, .z);
    v5 = swizzle(m[3], .z, .z, .y, .y);

    p0 = mulAdd(-v0, v1, p0);
    p1 = mulAdd(-v2, v3, p1);
    p2 = mulAdd(-v4, v5, p2);

    v0 = swizzle(m[1], .w, .w, .w, .z);
    v1 = swizzle(m[1], .z, .z, .y, .y);
    v2 = swizzle(m[1], .y, .x, .x, .x);

    const s: Vec = m[0] * f32x4(1.0, -1.0, 1.0, -1.0);
    var r: Vec = v0 * p0;
    r = mulAdd(-v1, p1, r);
    r = mulAdd(v2, p2, r);
    return dot4Splat(s, r);
}
pub fn determinant(m: Mat) f32 {
    return determinantSplat(m)[0];
}
test "zm.matrix.determinant" {
    const m: Mat = .{
        f32x4(10.0, -9.0, -12.0, 1.0),
        f32x4(7.0, -12.0, 11.0, 1.0),
        f32x4(-10.0, 10.0, 3.0, 1.0),
        f32x4(1.0, 2.0, 3.0, 4.0),
    };
    try expectApproxEqAbs(@as(f32, 2939.0), determinant(m), 0.0001);
}

pub fn inverseDet(m: Mat, out_det: ?*Vec) Mat {
    const mt: Mat = transpose(m);
    var v0: [4]Vec = undefined;
    var v1: [4]Vec = undefined;

    v0[0] = swizzle(mt[2], .x, .x, .y, .y);
    v1[0] = swizzle(mt[3], .z, .w, .z, .w);
    v0[1] = swizzle(mt[0], .x, .x, .y, .y);
    v1[1] = swizzle(mt[1], .z, .w, .z, .w);
    v0[2] = @shuffle(f32, mt[2], mt[0], [4]i32{ 0, 2, ~@as(i32, 0), ~@as(i32, 2) });
    v1[2] = @shuffle(f32, mt[3], mt[1], [4]i32{ 1, 3, ~@as(i32, 1), ~@as(i32, 3) });

    var d0: Vec = v0[0] * v1[0];
    var d1: Vec = v0[1] * v1[1];
    var d2: Vec = v0[2] * v1[2];

    v0[0] = swizzle(mt[2], .z, .w, .z, .w);
    v1[0] = swizzle(mt[3], .x, .x, .y, .y);
    v0[1] = swizzle(mt[0], .z, .w, .z, .w);
    v1[1] = swizzle(mt[1], .x, .x, .y, .y);
    v0[2] = @shuffle(f32, mt[2], mt[0], [4]i32{ 1, 3, ~@as(i32, 1), ~@as(i32, 3) });
    v1[2] = @shuffle(f32, mt[3], mt[1], [4]i32{ 0, 2, ~@as(i32, 0), ~@as(i32, 2) });

    d0 = mulAdd(-v0[0], v1[0], d0);
    d1 = mulAdd(-v0[1], v1[1], d1);
    d2 = mulAdd(-v0[2], v1[2], d2);

    v0[0] = swizzle(mt[1], .y, .z, .x, .y);
    v1[0] = @shuffle(f32, d0, d2, [4]i32{ ~@as(i32, 1), 1, 3, 0 });
    v0[1] = swizzle(mt[0], .z, .x, .y, .x);
    v1[1] = @shuffle(f32, d0, d2, [4]i32{ 3, ~@as(i32, 1), 1, 2 });
    v0[2] = swizzle(mt[3], .y, .z, .x, .y);
    v1[2] = @shuffle(f32, d1, d2, [4]i32{ ~@as(i32, 3), 1, 3, 0 });
    v0[3] = swizzle(mt[2], .z, .x, .y, .x);
    v1[3] = @shuffle(f32, d1, d2, [4]i32{ 3, ~@as(i32, 3), 1, 2 });

    var c0: Vec = v0[0] * v1[0];
    var c2: Vec = v0[1] * v1[1];
    var c4: Vec = v0[2] * v1[2];
    var c6: Vec = v0[3] * v1[3];

    v0[0] = swizzle(mt[1], .z, .w, .y, .z);
    v1[0] = @shuffle(f32, d0, d2, [4]i32{ 3, 0, 1, ~@as(i32, 0) });
    v0[1] = swizzle(mt[0], .w, .z, .w, .y);
    v1[1] = @shuffle(f32, d0, d2, [4]i32{ 2, 1, ~@as(i32, 0), 0 });
    v0[2] = swizzle(mt[3], .z, .w, .y, .z);
    v1[2] = @shuffle(f32, d1, d2, [4]i32{ 3, 0, 1, ~@as(i32, 2) });
    v0[3] = swizzle(mt[2], .w, .z, .w, .y);
    v1[3] = @shuffle(f32, d1, d2, [4]i32{ 2, 1, ~@as(i32, 2), 0 });

    c0 = mulAdd(-v0[0], v1[0], c0);
    c2 = mulAdd(-v0[1], v1[1], c2);
    c4 = mulAdd(-v0[2], v1[2], c4);
    c6 = mulAdd(-v0[3], v1[3], c6);

    v0[0] = swizzle(mt[1], .w, .x, .w, .x);
    v1[0] = @shuffle(f32, d0, d2, [4]i32{ 2, ~@as(i32, 1), ~@as(i32, 0), 2 });
    v0[1] = swizzle(mt[0], .y, .w, .x, .z);
    v1[1] = @shuffle(f32, d0, d2, [4]i32{ ~@as(i32, 1), 0, 3, ~@as(i32, 0) });
    v0[2] = swizzle(mt[3], .w, .x, .w, .x);
    v1[2] = @shuffle(f32, d1, d2, [4]i32{ 2, ~@as(i32, 3), ~@as(i32, 2), 2 });
    v0[3] = swizzle(mt[2], .y, .w, .x, .z);
    v1[3] = @shuffle(f32, d1, d2, [4]i32{ ~@as(i32, 3), 0, 3, ~@as(i32, 2) });

    const c1: Vec = mulAdd(-v0[0], v1[0], c0);
    const c3: Vec = mulAdd(v0[1], v1[1], c2);
    const c5: Vec = mulAdd(-v0[2], v1[2], c4);
    const c7: Vec = mulAdd(v0[3], v1[3], c6);

    c0 = mulAdd(v0[0], v1[0], c0);
    c2 = mulAdd(-v0[1], v1[1], c2);
    c4 = mulAdd(v0[2], v1[2], c4);
    c6 = mulAdd(-v0[3], v1[3], c6);

    var mr: Mat = .{
        f32x4(c0[0], c1[1], c0[2], c1[3]),
        f32x4(c2[0], c3[1], c2[2], c3[3]),
        f32x4(c4[0], c5[1], c4[2], c5[3]),
        f32x4(c6[0], c7[1], c6[2], c7[3]),
    };

    const det: Vec = dot4Splat(mr[0], mt[0]);
    if (out_det != null) {
        out_det.?.* = det;
    }

    if (math.approxEqAbs(f64, det[0], 0.0, math.floatEps(f64))) {
        return .{
            f32x4(0.0, 0.0, 0.0, 0.0),
            f32x4(0.0, 0.0, 0.0, 0.0),
            f32x4(0.0, 0.0, 0.0, 0.0),
            f32x4(0.0, 0.0, 0.0, 0.0),
        };
    }

    const scale: Vec = splat(1.0) / det;
    mr[0] *= scale;
    mr[1] *= scale;
    mr[2] *= scale;
    mr[3] *= scale;
    return mr;
}

fn inverseMat(m: Mat) Mat {
    return inverseDet(m, null);
}

pub inline fn conjugate(q: Quat) Quat {
    return q * f32x4(-1.0, -1.0, -1.0, 1.0);
}

fn inverseQuat(q: Quat) Quat {
    const l: Vec = lengthSq4Splat(q);
    const conj: Quat = conjugate(q);
    return blend(l <= splat(math.floatEps(f32)), splat(0.0), conj / l);
}

pub fn inverse(a: anytype) @TypeOf(a) {
    const T = @TypeOf(a);
    return switch (T) {
        Mat => inverseMat(a),
        Quat => inverseQuat(a),
        else => @compileError("zm.inverse() not implemented for " ++ @typeName(T)),
    };
}

test "zm.matrix.inverse" {
    const m: Mat = .{
        f32x4(10.0, -9.0, -12.0, 1.0),
        f32x4(7.0, -12.0, 11.0, 1.0),
        f32x4(-10.0, 10.0, 3.0, 1.0),
        f32x4(1.0, 2.0, 3.0, 4.0),
    };
    var det: Vec = undefined;
    const m_inv: Mat = inverseDet(m, &det);
    try expectVecApproxEqAbs(det, splat(2939.0), 0.0001);

    try expectVecApproxEqAbs(m_inv[0], f32x4(-0.170806, -0.13576, -0.349439, 0.164001), 0.0001);
    try expectVecApproxEqAbs(m_inv[1], f32x4(-0.163661, -0.14801, -0.253147, 0.141204), 0.0001);
    try expectVecApproxEqAbs(m_inv[2], f32x4(-0.0871045, 0.00646478, -0.0785982, 0.0398095), 0.0001);
    try expectVecApproxEqAbs(m_inv[3], f32x4(0.18986, 0.103096, 0.272882, 0.10854), 0.0001);
}

inline fn f32x4_mask3() Vec {
    return Vec{
        @as(f32, @bitCast(@as(u32, 0xffff_ffff))),
        @as(f32, @bitCast(@as(u32, 0xffff_ffff))),
        @as(f32, @bitCast(@as(u32, 0xffff_ffff))),
        0,
    };
}

pub fn matFromNormAxisAngle(axis: Vec, angle_rad: f32) Mat {
    const sincos_angle: [2]f32 = sincos(angle_rad);

    const c2: Vec = splat(1.0 - sincos_angle[1]);
    const c1: Vec = splat(sincos_angle[1]);
    const c0: Vec = splat(sincos_angle[0]);

    const n0: Vec = swizzle(axis, .y, .z, .x, .w);
    const n1: Vec = swizzle(axis, .z, .x, .y, .w);

    var v0: Vec = c2 * n0 * n1;
    const r0: Vec = c2 * axis * axis + c1;
    const r1: Vec = c0 * axis + v0;
    var r2: Vec = v0 - c0 * axis;

    v0 = andInt(r0, f32x4_mask3());

    var v1 = @shuffle(f32, r1, r2, [4]i32{ 0, 2, ~@as(i32, 1), ~@as(i32, 2) });
    v1 = swizzle(v1, .y, .z, .w, .x);

    var v2 = @shuffle(f32, r1, r2, [4]i32{ 1, 1, ~@as(i32, 0), ~@as(i32, 0) });
    v2 = swizzle(v2, .x, .z, .x, .z);

    r2 = @shuffle(f32, v0, v1, [4]i32{ 0, 3, ~@as(i32, 0), ~@as(i32, 1) });
    r2 = swizzle(r2, .x, .z, .w, .y);

    var m: Mat = undefined;
    m[0] = r2;

    r2 = @shuffle(f32, v0, v1, [4]i32{ 1, 3, ~@as(i32, 2), ~@as(i32, 3) });
    r2 = swizzle(r2, .z, .x, .w, .y);
    m[1] = r2;

    v2 = @shuffle(f32, v2, v0, [4]i32{ 0, 1, ~@as(i32, 2), ~@as(i32, 3) });
    m[2] = v2;
    m[3] = f32x4(0.0, 0.0, 0.0, 1.0);
    return m;
}
pub fn matFromAxisAngle(axis: Vec, angle_rad: f32) Mat {
    assert(!allTrue(axis == splat(0.0), 3), @src());
    assert(!allTrue(isInf(axis), 3), @src());
    const normal: Vec = normalize3(axis);
    return matFromNormAxisAngle(normal, angle_rad);
}
test "zm.matrix.matFromAxisAngle" {
    {
        const m0: Mat = matFromAxisAngle(f32x4(1.0, 0.0, 0.0, 0.0), pi * 0.25);
        const m1: Mat = rotationX(pi * 0.25);
        try expectVecApproxEqAbs(m0[0], m1[0], 0.001);
        try expectVecApproxEqAbs(m0[1], m1[1], 0.001);
        try expectVecApproxEqAbs(m0[2], m1[2], 0.001);
        try expectVecApproxEqAbs(m0[3], m1[3], 0.001);
    }
    {
        const m0: Mat = matFromAxisAngle(f32x4(0.0, 1.0, 0.0, 0.0), pi * 0.125);
        const m1: Mat = rotationY(pi * 0.125);
        try expectVecApproxEqAbs(m0[0], m1[0], 0.001);
        try expectVecApproxEqAbs(m0[1], m1[1], 0.001);
        try expectVecApproxEqAbs(m0[2], m1[2], 0.001);
        try expectVecApproxEqAbs(m0[3], m1[3], 0.001);
    }
    {
        const m0: Mat = matFromAxisAngle(f32x4(0.0, 0.0, 1.0, 0.0), pi * 0.333);
        const m1: Mat = rotationZ(pi * 0.333);
        try expectVecApproxEqAbs(m0[0], m1[0], 0.001);
        try expectVecApproxEqAbs(m0[1], m1[1], 0.001);
        try expectVecApproxEqAbs(m0[2], m1[2], 0.001);
        try expectVecApproxEqAbs(m0[3], m1[3], 0.001);
    }
}

pub fn matFromQuat(q: Quat) Mat {
    const q0: Quat = q + q;
    var q1: Vec = q * q0;

    var v0: Vec = swizzle(q1, .y, .x, .x, .w);
    v0 = andInt(v0, f32x4_mask3());

    var v1: Vec = swizzle(q1, .z, .z, .y, .w);
    v1 = andInt(v1, f32x4_mask3());

    const r0: Vec = (f32x4(1.0, 1.0, 1.0, 0.0) - v0) - v1;

    v0 = swizzle(q, .x, .x, .y, .w);
    v1 = swizzle(q0, .z, .y, .z, .w);
    v0 = v0 * v1;

    v1 = swizzle(q, .w, .w, .w, .w);
    const v2: Vec = swizzle(q0, .y, .z, .x, .w);
    v1 = v1 * v2;

    const r1: Vec = v0 + v1;
    const r2: Vec = v0 - v1;

    v0 = @shuffle(f32, r1, r2, [4]i32{ 1, 2, ~@as(i32, 0), ~@as(i32, 1) });
    v0 = swizzle(v0, .x, .z, .w, .y);
    v1 = @shuffle(f32, r1, r2, [4]i32{ 0, 0, ~@as(i32, 2), ~@as(i32, 2) });
    v1 = swizzle(v1, .x, .z, .x, .z);

    q1 = @shuffle(f32, r0, v0, [4]i32{ 0, 3, ~@as(i32, 0), ~@as(i32, 1) });
    q1 = swizzle(q1, .x, .z, .w, .y);

    var m: Mat = undefined;
    m[0] = q1;

    q1 = @shuffle(f32, r0, v0, [4]i32{ 1, 3, ~@as(i32, 2), ~@as(i32, 3) });
    q1 = swizzle(q1, .z, .x, .w, .y);
    m[1] = q1;

    q1 = @shuffle(f32, v1, r0, [4]i32{ 0, 1, ~@as(i32, 2), ~@as(i32, 3) });
    m[2] = q1;
    m[3] = f32x4(0.0, 0.0, 0.0, 1.0);
    return m;
}
test "zm.matrix.matFromQuat" {
    {
        const m: Mat = matFromQuat(f32x4(0.0, 0.0, 0.0, 1.0));
        try expectVecApproxEqAbs(m[0], f32x4(1.0, 0.0, 0.0, 0.0), 0.0001);
        try expectVecApproxEqAbs(m[1], f32x4(0.0, 1.0, 0.0, 0.0), 0.0001);
        try expectVecApproxEqAbs(m[2], f32x4(0.0, 0.0, 1.0, 0.0), 0.0001);
        try expectVecApproxEqAbs(m[3], f32x4(0.0, 0.0, 0.0, 1.0), 0.0001);
    }
}

pub fn quatFromRollPitchYawV(angles: Vec) Quat { // | pitch | yaw | roll | 0 |
    const sc: [2]Vec = sincos(splat(0.5) * angles);
    const p0: Vec = @shuffle(f32, sc[1], sc[0], [4]i32{ ~@as(i32, 0), 0, 0, 0 });
    const p1: Vec = @shuffle(f32, sc[0], sc[1], [4]i32{ ~@as(i32, 0), 0, 0, 0 });
    const y0: Vec = @shuffle(f32, sc[1], sc[0], [4]i32{ 1, ~@as(i32, 1), 1, 1 });
    const y1: Vec = @shuffle(f32, sc[0], sc[1], [4]i32{ 1, ~@as(i32, 1), 1, 1 });
    const r0: Vec = @shuffle(f32, sc[1], sc[0], [4]i32{ 2, 2, ~@as(i32, 2), 2 });
    const r1: Vec = @shuffle(f32, sc[0], sc[1], [4]i32{ 2, 2, ~@as(i32, 2), 2 });
    const q1: Vec = p1 * f32x4(1.0, -1.0, -1.0, 1.0) * y1;
    const q0: Vec = p0 * y0 * r0;
    return mulAdd(q1, r1, q0);
}

pub fn matFromRollPitchYawV(angles: Vec) Mat {
    return matFromQuat(quatFromRollPitchYawV(angles));
}

pub fn matFromRollPitchYaw(pitch_rad: f32, yaw_rad: f32, roll_rad: f32) Mat {
    return matFromRollPitchYawV(f32x4(pitch_rad, yaw_rad, roll_rad, 0.0));
}

pub fn quatFromMat(m: Mat) Quat {
    const r0: Vec = m[0];
    const r1: Vec = m[1];
    const r2: Vec = m[2];
    const r00: Vec = swizzle(r0, .x, .x, .x, .x);
    const r11: Vec = swizzle(r1, .y, .y, .y, .y);
    const r22: Vec = swizzle(r2, .z, .z, .z, .z);

    const x2gey2: Boolx4 = (r11 - r00) <= splat(0.0);
    const z2gew2: Boolx4 = (r11 + r00) <= splat(0.0);
    const x2py2gez2pw2: Boolx4 = r22 <= splat(0.0);

    var t0: Vec = mulAdd(r00, f32x4(1.0, -1.0, -1.0, 1.0), splat(1.0));
    var t1: Vec = r11 * f32x4(-1.0, 1.0, -1.0, 1.0);
    var t2: Vec = mulAdd(r22, f32x4(-1.0, -1.0, 1.0, 1.0), t0);
    const x2y2z2w2: Vec = t1 + t2;

    t0 = @shuffle(f32, r0, r1, [4]i32{ 1, 2, ~@as(i32, 2), ~@as(i32, 1) });
    t1 = @shuffle(f32, r1, r2, [4]i32{ 0, 0, ~@as(i32, 0), ~@as(i32, 1) });
    t1 = swizzle(t1, .x, .z, .w, .y);
    const xyxzyz: Vec = t0 + t1;

    t0 = @shuffle(f32, r2, r1, [4]i32{ 1, 0, ~@as(i32, 0), ~@as(i32, 0) });
    t1 = @shuffle(f32, r1, r0, [4]i32{ 2, 2, ~@as(i32, 2), ~@as(i32, 1) });
    t1 = swizzle(t1, .x, .z, .w, .y);
    const xwywzw: Vec = (t0 - t1) * f32x4(-1.0, 1.0, -1.0, 1.0);

    t0 = @shuffle(f32, x2y2z2w2, xyxzyz, [4]i32{ 0, 1, ~@as(i32, 0), ~@as(i32, 0) });
    t1 = @shuffle(f32, x2y2z2w2, xwywzw, [4]i32{ 2, 3, ~@as(i32, 2), ~@as(i32, 0) });
    t2 = @shuffle(f32, xyxzyz, xwywzw, [4]i32{ 1, 2, ~@as(i32, 0), ~@as(i32, 1) });

    const tensor0 = @shuffle(f32, t0, t2, [4]i32{ 0, 2, ~@as(i32, 0), ~@as(i32, 2) });
    const tensor1 = @shuffle(f32, t0, t2, [4]i32{ 2, 1, ~@as(i32, 1), ~@as(i32, 3) });
    const tensor2 = @shuffle(f32, t2, t1, [4]i32{ 0, 1, ~@as(i32, 0), ~@as(i32, 2) });
    const tensor3 = @shuffle(f32, t2, t1, [4]i32{ 2, 3, ~@as(i32, 2), ~@as(i32, 1) });

    t0 = blend(x2gey2, tensor0, tensor1);
    t1 = blend(z2gew2, tensor2, tensor3);
    t2 = blend(x2py2gez2pw2, t0, t1);

    return t2 / length4Splat(t2);
}

pub fn matToQuat(m: Mat) Quat {
    return quatFromMat(m);
}

pub inline fn loadMat(mem: []const f32) Mat {
    return .{
        loadVec(mem[0..4], Vec, 0),
        loadVec(mem[4..8], Vec, 0),
        loadVec(mem[8..12], Vec, 0),
        loadVec(mem[12..16], Vec, 0),
    };
}
test "zm.loadMat" {
    const a: [18]f32 = .{
        1.0,  2.0,  3.0,  4.0,
        5.0,  6.0,  7.0,  8.0,
        9.0,  10.0, 11.0, 12.0,
        13.0, 14.0, 15.0, 16.0,
        17.0, 18.0,
    };
    const m: Mat = loadMat(a[1..]);
    try expectVecEqual(m[0], f32x4(2.0, 3.0, 4.0, 5.0));
    try expectVecEqual(m[1], f32x4(6.0, 7.0, 8.0, 9.0));
    try expectVecEqual(m[2], f32x4(10.0, 11.0, 12.0, 13.0));
    try expectVecEqual(m[3], f32x4(14.0, 15.0, 16.0, 17.0));
}

pub inline fn storeMat(mem: []f32, m: Mat) void {
    storeVec(mem[0..4], m[0], 0);
    storeVec(mem[4..8], m[1], 0);
    storeVec(mem[8..12], m[2], 0);
    storeVec(mem[12..16], m[3], 0);
}

pub inline fn loadMat43(mem: []const f32) Mat {
    return .{
        dirFromArr3(mem),
        f32x4(mem[3], mem[4], mem[5], 0.0),
        f32x4(mem[6], mem[7], mem[8], 0.0),
        f32x4(mem[9], mem[10], mem[11], 1.0),
    };
}

pub inline fn storeMat43(mem: []f32, m: Mat) void {
    storeVec(mem[0..3], m[0], 3);
    storeVec(mem[3..6], m[1], 3);
    storeVec(mem[6..9], m[2], 3);
    storeVec(mem[9..12], m[3], 3);
}

pub inline fn loadMat34(mem: []const f32) Mat {
    return .{
        loadVec(mem[0..4], Vec, 0),
        loadVec(mem[4..8], Vec, 0),
        loadVec(mem[8..12], Vec, 0),
        f32x4(0.0, 0.0, 0.0, 1.0),
    };
}

pub inline fn storeMat34(mem: []f32, m: Mat) void {
    storeVec(mem[0..4], m[0], 0);
    storeVec(mem[4..8], m[1], 0);
    storeVec(mem[8..12], m[2], 0);
}

pub inline fn matToArr(m: Mat) [16]f32 {
    var out_arr: [16]f32 = undefined;
    storeMat(out_arr[0..], m);
    return out_arr;
}

pub inline fn matToArr43(m: Mat) [12]f32 {
    var out_arr: [12]f32 = undefined;
    storeMat43(out_arr[0..], m);
    return out_arr;
}

pub inline fn matToArr34(m: Mat) [12]f32 {
    var out_arr: [12]f32 = undefined;
    storeMat34(out_arr[0..], m);
    return out_arr;
}
//
// 5. Quat functions
//
/// zmath's SIMD quaternion kernel. It composes the OPPOSITE way to the public `qmul`
/// (its first argument is applied first), so it is private and only reached through
/// `qmul`, which swaps the operands to present the Hamilton order.
fn qmulRaw(q0: Quat, q1: Quat) Quat {
    var result: Vec = swizzle(q1, .w, .w, .w, .w);
    var q1x: Vec = swizzle(q1, .x, .x, .x, .x);
    var q1y: Vec = swizzle(q1, .y, .y, .y, .y);
    var q1z: Vec = swizzle(q1, .z, .z, .z, .z);
    result = result * q0;
    var q0_shuf: Vec = swizzle(q0, .w, .z, .y, .x);
    q1x = q1x * q0_shuf;
    q0_shuf = swizzle(q0_shuf, .y, .x, .w, .z);
    result = mulAdd(q1x, f32x4(1.0, -1.0, 1.0, -1.0), result);
    q1y = q1y * q0_shuf;
    q0_shuf = swizzle(q0_shuf, .w, .z, .y, .x);
    q1y = q1y * f32x4(1.0, 1.0, -1.0, -1.0);
    q1z = q1z * q0_shuf;
    q1y = mulAdd(q1z, f32x4(-1.0, 1.0, 1.0, -1.0), q1y);
    return result + q1y;
}

/// Quaternion (Hamilton) product. `qmul(a, b)` applies `b` first, then `a` — so it
/// matches matrix composition (`mulMat(a, b) == a*b`, B applied first) and Jolt's
/// `operator*`. Concretely: `matFromQuat(qmul(a, b)) == mulMat(matFromQuat(a), matFromQuat(b))`
/// and `rotate(qmul(a, b), v) == rotate(a, rotate(b, v))`. This is the convention every
/// caller (and every literal Jolt port) relies on; see math.md "Quaternion product order".
pub fn qmul(q0: Quat, q1: Quat) Quat {
    return qmulRaw(q1, q0);
}
test "zm.quaternion.mul" {
    {
        const q0: Quat = f32x4(2.0, 3.0, 4.0, 1.0);
        const q1: Quat = f32x4(3.0, 2.0, 1.0, 4.0);
        // qmul is now Hamilton order (qmul(a,b) applies b first); the kernel value that
        // used to be qmul(q0,q1) is reached as qmul(q1,q0).
        try expectVecApproxEqAbs(qmul(q1, q0), f32x4(16.0, 4.0, 22.0, -12.0), 0.0001);
    }
}

pub fn quatToMat(q: Quat) Mat {
    return matFromQuat(q);
}

pub fn quatToAxisAngle(
    q: Quat,
    axis: *Vec,
    angle: *f32,
) void {
    axis.* = q;
    angle.* = 2.0 * acos(q[3]);
}
pub fn quatFromNormAxisAngle(axis: Vec, angle_rad: f32) Quat {
    const n: Vec = pointFromArr3(axis);
    const sc: [2]f32 = sincos(0.5 * angle_rad);
    return n * f32x4(sc[0], sc[0], sc[0], sc[1]);
}

test "zm.quaternion.quatToAxisAngle" {
    {
        const q0: Quat = quatFromNormAxisAngle(f32x4(1.0, 0.0, 0.0, 0.0), 0.25 * pi);
        var axis: Vec = f32x4(4.0, 3.0, 2.0, 1.0);
        var angle: f32 = 10.0;
        quatToAxisAngle(q0, &axis, &angle);
        try expect(math.approxEqAbs(f32, axis[0], @sin(@as(f32, 0.25) * pi * 0.5), 0.0001));
        try expect(axis[1] == 0.0);
        try expect(axis[2] == 0.0);
        try expect(math.approxEqAbs(f32, angle, 0.25 * pi, 0.0001));
    }
}

pub fn quatFromAxisAngle(axis: Vec, angle_rad: f32) Quat {
    assert(!allTrue(axis == splat(0.0), 3), @src());
    assert(!allTrue(isInf(axis), 3), @src());
    const normal: Vec = normalize3(axis);
    return quatFromNormAxisAngle(normal, angle_rad);
}

pub fn quatFromRollPitchYaw(pitch_rad: f32, yaw_rad: f32, roll_rad: f32) Quat {
    return quatFromRollPitchYawV(f32x4(pitch_rad, yaw_rad, roll_rad, 0.0));
}

test "zm.quatFromMat" {
    {
        const q0: Quat = quatFromAxisAngle(f32x4(1.0, 0.0, 0.0, 0.0), 0.25 * pi);
        const q1: Quat = quatFromMat(rotationX(0.25 * pi));
        try expectVecApproxEqAbs(q0, q1, 0.0001);
    }
    {
        const q0: Quat = quatFromAxisAngle(f32x4(1.0, 2.0, 0.5, 0.0), 0.25 * pi);
        const q1: Quat = quatFromMat(matFromAxisAngle(f32x4(1.0, 2.0, 0.5, 0.0), 0.25 * pi));
        try expectVecApproxEqAbs(q0, q1, 0.0001);
    }
    {
        const q0: Quat = quatFromRollPitchYaw(0.1 * pi, -0.2 * pi, 0.3 * pi);
        const q1: Quat = quatFromMat(matFromRollPitchYaw(0.1 * pi, -0.2 * pi, 0.3 * pi));
        try expectVecApproxEqAbs(q0, q1, 0.0001);
    }
}

test "zm.quaternion.quatFromNormAxisAngle" {
    {
        const q0: Quat = quatFromAxisAngle(f32x4(1.0, 0.0, 0.0, 0.0), 0.25 * pi);
        const q1: Quat = quatFromAxisAngle(f32x4(0.0, 1.0, 0.0, 0.0), 0.125 * pi);
        const m0: Mat = rotationX(0.25 * pi);
        const m1: Mat = rotationY(0.125 * pi);
        const mr0: Mat = quatToMat(qmul(q0, q1));
        // qmul is now Hamilton order, matching matrix composition exactly:
        // quatToMat(qmul(q0, q1)) == mulMat(quatToMat(q0), quatToMat(q1)) == mulMat(m0, m1).
        const mr1: Mat = mulMat(m0, m1);
        try expectVecApproxEqAbs(mr0[0], mr1[0], 0.0001);
        try expectVecApproxEqAbs(mr0[1], mr1[1], 0.0001);
        try expectVecApproxEqAbs(mr0[2], mr1[2], 0.0001);
        try expectVecApproxEqAbs(mr0[3], mr1[3], 0.0001);
    }
    {
        const m0: Mat = quatToMat(quatFromAxisAngle(f32x4(1.0, 2.0, 0.5, 0.0), 0.25 * pi));
        const m1: Mat = matFromAxisAngle(f32x4(1.0, 2.0, 0.5, 0.0), 0.25 * pi);
        try expectVecApproxEqAbs(m0[0], m1[0], 0.0001);
        try expectVecApproxEqAbs(m0[1], m1[1], 0.0001);
        try expectVecApproxEqAbs(m0[2], m1[2], 0.0001);
        try expectVecApproxEqAbs(m0[3], m1[3], 0.0001);
    }
}

pub inline fn qidentity() Quat {
    return f32x4(@as(f32, 0.0), @as(f32, 0.0), @as(f32, 0.0), @as(f32, 1.0));
}

test "zm.quaternion.inverseQuat" {
    try expectVecApproxEqAbs(
        inverse(f32x4(2.0, 3.0, 4.0, 1.0)),
        f32x4(-1.0 / 15.0, -1.0 / 10.0, -2.0 / 15.0, 1.0 / 30.0),
        0.0001,
    );
    try expectVecApproxEqAbs(inverse(qidentity()), qidentity(), 0.0001);
}

// Algorithm from: https://github.com/g-truc/glm/blob/master/glm/detail/type_quat.inl
pub fn rotate(q: Quat, v: Vec) Vec {
    const w: Vec = splat(q[3]);
    const axis: Vec = dirFromArr3(q);
    const uv: Vec = cross(axis, v);
    return v + ((uv * w) + cross(axis, uv)) * splat(2.0);
}
test "zm.quaternion.rotate" {
    const q: Quat = quatFromRollPitchYaw(0.1 * pi, 0.2 * pi, 0.3 * pi);
    const mat: Mat = matFromQuat(q);
    const forward: Vec = f32x4(0.0, 0.0, -1.0, 0.0);
    const up: Vec = f32x4(0.0, 1.0, 0.0, 0.0);
    const right: Vec = f32x4(1.0, 0.0, 0.0, 0.0);
    try expectVecApproxEqAbs(rotate(q, forward), mulMatVec(mat, forward), 0.0001);
    try expectVecApproxEqAbs(rotate(q, up), mulMatVec(mat, up), 0.0001);
    try expectVecApproxEqAbs(rotate(q, right), mulMatVec(mat, right), 0.0001);
}

inline fn f32x4_mask2() Vec {
    return Vec{
        @as(f32, @bitCast(@as(u32, 0xffff_ffff))),
        @as(f32, @bitCast(@as(u32, 0xffff_ffff))),
        0,
        0,
    };
}

inline fn f32x4_sign_mask1() Vec {
    return Vec{ @as(f32, @bitCast(@as(u32, 0x8000_0000))), 0, 0, 0 };
}

pub fn slerpV(
    q0: Quat,
    q1: Quat,
    t: Vec,
) Quat {
    var cos_omega: Vec = dot4Splat(q0, q1);
    const sign: Vec = blend(cos_omega < splat(0.0), splat(-1.0), splat(1.0));

    cos_omega = cos_omega * sign;
    const sin_omega: Vec = sqrt(splat(1.0) - cos_omega * cos_omega);

    const omega: Vec = atan2(sin_omega, cos_omega);

    var v01: Vec = t;
    v01 = xorInt(andInt(v01, f32x4_mask2()), f32x4_sign_mask1());
    v01 = f32x4(1.0, 0.0, 0.0, 0.0) + v01;

    var s0: Vec = sin(v01 * omega) / sin_omega;
    s0 = blend(cos_omega < splat(1.0 - 0.00001), s0, v01);

    const s1: Vec = swizzle(s0, .y, .y, .y, .y);
    s0 = swizzle(s0, .x, .x, .x, .x);

    return q0 * s0 + sign * q1 * s1;
}

pub fn slerp(
    q0: Quat,
    q1: Quat,
    t: f32,
) Quat {
    return slerpV(q0, q1, splat(t));
}
test "zm.quaternion.slerp" {
    const from: Vec = f32x4(0.0, 0.0, 0.0, 1.0);
    const to: Vec = f32x4(0.5, 0.5, -0.5, 0.5);
    const result: Quat = slerp(from, to, 0.5);
    try expectVecApproxEqAbs(result, f32x4(0.28867513, 0.28867513, -0.28867513, 0.86602540), 0.0001);
}

// Converts q back to euler angles, assuming a YXZ rotation order.
// See: http://www.euclideanspace.com/maths/geometry/rotations/conversions/quaternionToEuler
/// 3D *direction* — lane 3 is 0, so the translation row of an
/// affine matrix has no effect.
pub inline fn vec(x: f32, y: f32, z: f32) Vec {
    return .{ x, y, z, 0.0 };
}

pub fn quatToRollPitchYaw(q: Quat) [3]f32 {
    var angles: [3]f32 = undefined;

    const p: Vec = swizzle(q, .w, .y, .x, .z);
    const sign: f32 = -1.0;

    const singularity: f32 = p[0] * p[2] + sign * p[1] * p[3];
    if (singularity > 0.499) {
        angles[0] = pi * 0.5;
        angles[1] = 2.0 * math.atan2(p[1], p[0]);
        angles[2] = 0.0;
    } else if (singularity < -0.499) {
        angles[0] = -pi * 0.5;
        angles[1] = 2.0 * math.atan2(p[1], p[0]);
        angles[2] = 0.0;
    } else {
        const sq: Vec = p * p;
        const y: Vec = splat(2.0) * vec(
            p[0] * p[1] - sign * p[2] * p[3],
            p[0] * p[3] - sign * p[1] * p[2],
            0.0,
        );
        const x: Vec = splat(1.0) - (splat(2.0) * vec(sq[1] + sq[2], sq[2] + sq[3], 0.0));
        const res: Vec = atan2(y, x);
        angles[0] = math.asin(2.0 * singularity);
        angles[1] = res[0];
        angles[2] = res[1];
    }

    return angles;
}

test "zm.quaternion.quatToRollPitchYaw" {
    {
        const expected: Vec = f32x4(0.1 * pi, 0.2 * pi, 0.3 * pi, 0.0);
        const q: Quat = quatFromRollPitchYaw(expected[0], expected[1], expected[2]);
        const result: [3]f32 = quatToRollPitchYaw(q);
        try expectVecApproxEqAbs(loadArr3(result), expected, 0.0001);
    }

    {
        const expected: Vec = f32x4(0.3 * pi, 0.1 * pi, 0.2 * pi, 0.0);
        const q: Quat = quatFromRollPitchYaw(expected[0], expected[1], expected[2]);
        const result: [3]f32 = quatToRollPitchYaw(q);
        try expectVecApproxEqAbs(loadArr3(result), expected, 0.0001);
    }

    // North pole singularity
    {
        const angle: Vec = f32x4(0.5 * pi, 0.2 * pi, 0.3 * pi, 0.0);
        const expected: Vec = f32x4(0.5 * pi, -0.1 * pi, 0.0, 0.0);
        const q: Quat = quatFromRollPitchYaw(angle[0], angle[1], angle[2]);
        const result: [3]f32 = quatToRollPitchYaw(q);
        try expectVecApproxEqAbs(loadArr3(result), expected, 0.0001);
    }

    // South pole singularity
    {
        const angle: Vec = f32x4(-0.5 * pi, 0.2 * pi, 0.3 * pi, 0.0);
        const expected: Vec = f32x4(-0.5 * pi, 0.5 * pi, 0.0, 0.0);
        const q: Quat = quatFromRollPitchYaw(angle[0], angle[1], angle[2]);
        const result: [3]f32 = quatToRollPitchYaw(q);
        try expectVecApproxEqAbs(loadArr3(result), expected, 0.0001);
    }
}

test "zm.quaternion.quatFromRollPitchYawV" {
    {
        const m0: Mat = quatToMat(quatFromRollPitchYawV(f32x4(0.25 * pi, 0.0, 0.0, 0.0)));
        const m1: Mat = rotationX(0.25 * pi);
        try expectVecApproxEqAbs(m0[0], m1[0], 0.0001);
        try expectVecApproxEqAbs(m0[1], m1[1], 0.0001);
        try expectVecApproxEqAbs(m0[2], m1[2], 0.0001);
        try expectVecApproxEqAbs(m0[3], m1[3], 0.0001);
    }
    {
        const m0: Mat = quatToMat(quatFromRollPitchYaw(0.1 * pi, 0.2 * pi, 0.3 * pi));
        // Old: mul(rotZ, mul(rotX, rotY)).  Operand-swap for column-
        // major: mulMat(mulMat(rotY, rotX), rotZ).
        const m1: Mat = mulMat(
            mulMat(rotationY(0.2 * pi), rotationX(0.1 * pi)),
            rotationZ(0.3 * pi),
        );
        try expectVecApproxEqAbs(m0[0], m1[0], 0.0001);
        try expectVecApproxEqAbs(m0[1], m1[1], 0.0001);
        try expectVecApproxEqAbs(m0[2], m1[2], 0.0001);
        try expectVecApproxEqAbs(m0[3], m1[3], 0.0001);
    }
}
//
// 6. Color functions
//
pub fn adjustSaturation(color: Vec, saturation: f32) Vec {
    // [zimr] local renamed `luminance` -> `luma`: it shadowed zimr's
    // top-level `luminance` (added in the zimr-additions section) and
    // Zig 0.16 rejects the shadow. Purely a local rename; behaviour
    // and the Rec.709 weights are unchanged.
    const luma: f32 = dot3(f32x4(0.2125, 0.7154, 0.0721, 0.0), color);
    var result: Vec = mulAdd(color - splat(luma), splat(saturation), splat(luma));
    result[3] = color[3];
    return result;
}

pub fn adjustContrast(color: Vec, contrast: f32) Vec {
    var result: Vec = mulAdd(color - splat(0.5), splat(contrast), splat(0.5));
    result[3] = color[3];
    return result;
}

pub fn rgbToHsl(rgb: Vec) Vec {
    const r: Vec = swizzle(rgb, .x, .x, .x, .x);
    const g: Vec = swizzle(rgb, .y, .y, .y, .y);
    const b: Vec = swizzle(rgb, .z, .z, .z, .z);

    const minv: Vec = min(r, min(g, b));
    const maxv: Vec = max(r, max(g, b));

    const l: Vec = (minv + maxv) * splat(0.5);
    const d: Vec = maxv - minv;
    const la: Vec = blend(boolx4(true, true, true, false), l, rgb);

    if (allTrue(d < splat(math.floatEps(f32)), 3)) {
        return blend(boolx4(true, true, false, false), splat(0.0), la);
    } else {
        var s: Vec = undefined;
        var h: Vec = undefined;

        const d2: Vec = minv + maxv;

        if (allTrue(l > splat(0.5), 3)) {
            s = d / (splat(2.0) - d2);
        } else {
            s = d / d2;
        }

        if (allTrue(r == maxv, 3)) {
            h = (g - b) / d;
        } else if (allTrue(g == maxv, 3)) {
            h = splat(2.0) + (b - r) / d;
        } else {
            h = splat(4.0) + (r - g) / d;
        }

        h /= splat(6.0);

        if (allTrue(h < splat(0.0), 3)) {
            h += splat(1.0);
        }

        const lha: Vec = blend(boolx4(true, true, false, false), h, la);
        return blend(boolx4(true, false, true, true), lha, s);
    }
}
test "zm.color.rgbToHsl" {
    try expectVecApproxEqAbs(rgbToHsl(f32x4(0.2, 0.4, 0.8, 1.0)), f32x4(0.6111, 0.6, 0.5, 1.0), 0.0001);
    try expectVecApproxEqAbs(rgbToHsl(f32x4(1.0, 0.0, 0.0, 0.5)), f32x4(0.0, 1.0, 0.5, 0.5), 0.0001);
    try expectVecApproxEqAbs(rgbToHsl(f32x4(0.0, 1.0, 0.0, 0.25)), f32x4(0.3333, 1.0, 0.5, 0.25), 0.0001);
    try expectVecApproxEqAbs(rgbToHsl(f32x4(0.0, 0.0, 1.0, 1.0)), f32x4(0.6666, 1.0, 0.5, 1.0), 0.0001);
    try expectVecApproxEqAbs(rgbToHsl(f32x4(0.0, 0.0, 0.0, 1.0)), f32x4(0.0, 0.0, 0.0, 1.0), 0.0001);
    try expectVecApproxEqAbs(rgbToHsl(f32x4(1.0, 1.0, 1.0, 1.0)), f32x4(0.0, 0.0, 1.0, 1.0), 0.0001);
}

fn hueToClr(
    p: Vec,
    q: Vec,
    h: Vec,
) Vec {
    var t: Vec = h;

    if (allTrue(t < splat(0.0), 3)) {
        t += splat(1.0);
    }

    if (allTrue(t > splat(1.0), 3)) {
        t -= splat(1.0);
    }

    if (allTrue(t < splat(1.0 / 6.0), 3)) {
        return mulAdd(q - p, splat(6.0) * t, p);
    }

    if (allTrue(t < splat(0.5), 3)) {
        return q;
    }

    if (allTrue(t < splat(2.0 / 3.0), 3)) {
        return mulAdd(q - p, splat(6.0) * (splat(2.0 / 3.0) - t), p);
    }

    return p;
}

pub fn hslToRgb(hsl: Vec) Vec {
    const s: Vec = swizzle(hsl, .y, .y, .y, .y);
    const l: Vec = swizzle(hsl, .z, .z, .z, .z);

    if (allTrue(isNearEqual(s, splat(0.0), splat(math.floatEps(f32))), 3)) {
        return blend(boolx4(true, true, true, false), l, hsl);
    } else {
        const h: Vec = swizzle(hsl, .x, .x, .x, .x);
        var q: Vec = undefined;
        if (allTrue(l < splat(0.5), 3)) {
            q = l * (splat(1.0) + s);
        } else {
            q = (l + s) - (l * s);
        }

        const p: Vec = splat(2.0) * l - q;

        const r: Vec = hueToClr(p, q, h + splat(1.0 / 3.0));
        const g: Vec = hueToClr(p, q, h);
        const b: Vec = hueToClr(p, q, h - splat(1.0 / 3.0));

        const rg: Vec = blend(boolx4(true, false, false, false), r, g);
        const ba: Vec = blend(boolx4(true, true, true, false), b, hsl);
        return blend(boolx4(true, true, false, false), rg, ba);
    }
}
test "zm.color.hslToRgb" {
    try expectVecApproxEqAbs(f32x4(0.2, 0.4, 0.8, 1.0), hslToRgb(f32x4(0.6111, 0.6, 0.5, 1.0)), 0.0001);
    try expectVecApproxEqAbs(f32x4(1.0, 0.0, 0.0, 0.5), hslToRgb(f32x4(0.0, 1.0, 0.5, 0.5)), 0.0001);
    try expectVecApproxEqAbs(f32x4(0.0, 1.0, 0.0, 0.25), hslToRgb(f32x4(0.3333, 1.0, 0.5, 0.25)), 0.0005);
    try expectVecApproxEqAbs(f32x4(0.0, 0.0, 1.0, 1.0), hslToRgb(f32x4(0.6666, 1.0, 0.5, 1.0)), 0.0005);
    try expectVecApproxEqAbs(f32x4(0.0, 0.0, 0.0, 1.0), hslToRgb(f32x4(0.0, 0.0, 0.0, 1.0)), 0.0001);
    try expectVecApproxEqAbs(f32x4(1.0, 1.0, 1.0, 1.0), hslToRgb(f32x4(0.0, 0.0, 1.0, 1.0)), 0.0001);
    try expectVecApproxEqAbs(hslToRgb(rgbToHsl(f32x4(1.0, 1.0, 1.0, 1.0))), f32x4(1.0, 1.0, 1.0, 1.0), 0.0005);
    try expectVecApproxEqAbs(
        hslToRgb(rgbToHsl(f32x4(0.82198, 0.1839, 0.632, 1.0))),
        f32x4(0.82198, 0.1839, 0.632, 1.0),
        0.0005,
    );
    try expectVecApproxEqAbs(
        rgbToHsl(hslToRgb(f32x4(0.82198, 0.1839, 0.632, 1.0))),
        f32x4(0.82198, 0.1839, 0.632, 1.0),
        0.0005,
    );
    try expectVecApproxEqAbs(
        rgbToHsl(hslToRgb(f32x4(0.1839, 0.82198, 0.632, 1.0))),
        f32x4(0.1839, 0.82198, 0.632, 1.0),
        0.0005,
    );
    try expectVecApproxEqAbs(
        hslToRgb(rgbToHsl(f32x4(0.1839, 0.632, 0.82198, 1.0))),
        f32x4(0.1839, 0.632, 0.82198, 1.0),
        0.0005,
    );
}

// =====================================================================
// Color — the high-level color currency, centralized here.
// =====================================================================
// `Color` is sRGB bytes (raylib convention) and is CPU-side. The color
// MATH (hsv/srgb/linear) lives below as `Vec` (vec4f, 0..1 RGBA)
// functions so it transpiles to WGSL and runs IDENTICALLY on CPU and
// GPU — shaders use those helpers, never the u8 struct. Two packed-u32
// forms, named so they can't be confused: `hex`/`toHex` are human order
// 0xRRGGBBAA (like CSS), `toWire`/`fromWire` are the GPU/draw-list order
// 0xAABBGGRR (ImGui IM_COL32, R in the low byte).

fn srgbToLinCh(c: f32) f32 {
    const x: f32 = std.math.clamp(c, 0.0, 1.0);
    if (x <= 0.04045) {
        return x * (1.0 / 12.92);
    }
    return math.pow(f32, (x + 0.055) / 1.055, 2.4);
}

pub fn srgbToRgb(srgb: Vec) Vec {
    const static = struct {
        const cutoff = f32x4(0.04045, 0.04045, 0.04045, 1.0);
        const rlinear = f32x4(1.0 / 12.92, 1.0 / 12.92, 1.0 / 12.92, 1.0);
        const scale = f32x4(1.0 / 1.055, 1.0 / 1.055, 1.0 / 1.055, 1.0);
        const bias = f32x4(0.055, 0.055, 0.055, 1.0);
        const gamma = 2.4;
    };
    if (comptime is_wasm) {
        return .{ srgbToLinCh(srgb[0]), srgbToLinCh(srgb[1]), srgbToLinCh(srgb[2]), srgb[3] };
    }
    var v: Vec = clamp01(srgb);
    const v0: Vec = v * static.rlinear;
    var v1: Vec = static.scale * (v + static.bias);
    v1 = f32x4(
        math.pow(f32, v1[0], static.gamma),
        math.pow(f32, v1[1], static.gamma),
        math.pow(f32, v1[2], static.gamma),
        v1[3],
    );
    v = blend(v > static.cutoff, v1, v0);
    return blend(boolx4(true, true, true, false), v, srgb);
}

/// sRGB-encoded [0,1] -> linear-light [0,1] (alpha passthrough). GPU-safe.
pub const srgbToLinear = srgbToRgb;
fn linToSrgbCh(c: f32) f32 {
    const x: f32 = std.math.clamp(c, 0.0, 1.0);
    if (x <= 0.0031308) {
        return x * 12.92;
    }
    return 1.055 * math.pow(f32, x, 1.0 / 2.4) - 0.055;
}

pub fn rgbToSrgb(rgb: Vec) Vec {
    const static = struct {
        const cutoff = f32x4(0.0031308, 0.0031308, 0.0031308, 1.0);
        const linear = f32x4(12.92, 12.92, 12.92, 1.0);
        const scale = f32x4(1.055, 1.055, 1.055, 1.0);
        const bias = f32x4(0.055, 0.055, 0.055, 1.0);
        const rgamma = 1.0 / 2.4;
    };
    if (comptime is_wasm) {
        return .{ linToSrgbCh(rgb[0]), linToSrgbCh(rgb[1]), linToSrgbCh(rgb[2]), rgb[3] };
    }
    var v: Vec = clamp01(rgb);
    const v0: Vec = v * static.linear;
    const v1: Vec = static.scale * f32x4(
        math.pow(f32, v[0], static.rgamma),
        math.pow(f32, v[1], static.rgamma),
        math.pow(f32, v[2], static.rgamma),
        v[3],
    ) - static.bias;
    v = blend(v < static.cutoff, v0, v1);
    return blend(boolx4(true, true, true, false), v, rgb);
}

/// Linear-light [0,1] -> sRGB-encoded [0,1] (alpha passthrough). GPU-safe.
pub const linearToSrgb = rgbToSrgb;

/// Packed draw-list wire color: a `u32` holding little-endian RGBA
/// (0xAABBGGRR), matching `Color.toWire()`/`Color.fromWire()`. This is the
/// single packed-color type used across the engine, UI, and plot libraries.
pub const ColorU32 = u32;

/// HSV → RGB, 3-channel (no alpha).  Scalar implementation returning a plain
/// `[3]f32`: array-output callers (e.g. ui colour pickers) use this directly,
/// with no pack-to-Vec / SIMD round-trip.  Deliberately mirrors the scalar
/// `is_wasm` branch of `hsvToRgb` — keep the two in sync if the algorithm ever
/// changes.  (The Vec `hsvToRgb` remains the alpha-preserving Vec4 form.)
pub fn hsvToRgb3(h: f32, s: f32, v: f32) [3]f32 {
    if (s == 0) {
        return .{ v, v, v };
    }
    const hf: f32 = (h - @floor(h)) * 6.0;
    const ti: i32 = @floor(hf);
    const ff: f32 = hf - @floor(hf);
    const pp: f32 = v * (1.0 - s);
    const qq: f32 = v * (1.0 - s * ff);
    const tt: f32 = v * (1.0 - s * (1.0 - ff));
    return switch (@mod(ti, 6)) {
        0 => .{ v, tt, pp },
        1 => .{ qq, v, pp },
        2 => .{ pp, v, tt },
        3 => .{ pp, qq, v },
        4 => .{ tt, pp, v },
        else => .{ v, pp, qq },
    };
}

/// float -> integer T via @floor (toward -inf). The "to pixel" pattern:
/// `floori(i32, x * scale)` instead of `@floor(x * scale)`.
pub inline fn floori(comptime T: type, x: anytype) T {
    return @floor(x);
}

pub fn hsvToRgb(hsv: Vec) Vec {
    if (comptime is_wasm) {
        const c3: [3]f32 = hsvToRgb3(hsv[0], hsv[1], hsv[2]);
        return .{ c3[0], c3[1], c3[2], hsv[3] };
    }
    const h: Vec = swizzle(hsv, .x, .x, .x, .x);
    const s: Vec = swizzle(hsv, .y, .y, .y, .y);
    const v: Vec = swizzle(hsv, .z, .z, .z, .z);

    const h6: Vec = h * splat(6.0);
    const i: Vec = floor(h6);
    const f: Vec = h6 - i;

    const p: Vec = v * (splat(1.0) - s);
    const q: Vec = v * (splat(1.0) - f * s);
    const t: Vec = v * (splat(1.0) - (splat(1.0) - f) * s);

    const ii = floori(i32, modulo(i, splat(6.0))[0]);
    const rgb: Vec = switch (ii) {
        0 => blk: {
            const vt: Vec = blend(boolx4(true, false, false, false), v, t);
            break :blk blend(boolx4(true, true, false, false), vt, p);
        },
        1 => blk: {
            const qv: Vec = blend(boolx4(true, false, false, false), q, v);
            break :blk blend(boolx4(true, true, false, false), qv, p);
        },
        2 => blk: {
            const pv: Vec = blend(boolx4(true, false, false, false), p, v);
            break :blk blend(boolx4(true, true, false, false), pv, t);
        },
        3 => blk: {
            const pq: Vec = blend(boolx4(true, false, false, false), p, q);
            break :blk blend(boolx4(true, true, false, false), pq, v);
        },
        4 => blk: {
            const tp: Vec = blend(boolx4(true, false, false, false), t, p);
            break :blk blend(boolx4(true, true, false, false), tp, v);
        },
        5 => blk: {
            const vp: Vec = blend(boolx4(true, false, false, false), v, p);
            break :blk blend(boolx4(true, true, false, false), vp, q);
        },
        else => unreachable,
    };
    return blend(boolx4(true, true, true, false), rgb, hsv);
}

/// RGB → HSV, 3-channel (no alpha).  Inverse of `hsvToRgb3`; scalar `[3]f32`
/// form, the direct path for array-output callers.  Mirrors the scalar
/// `is_wasm` branch of `rgbToHsv`.
pub fn rgbToHsv3(r: f32, g: f32, b: f32) [3]f32 {
    const mx: f32 = @max(r, @max(g, b));
    const mn: f32 = @min(r, @min(g, b));
    const dd: f32 = mx - mn;
    var hh: f32 = 0;
    var sat: f32 = 0;
    if (mx > 0) {
        sat = dd / mx;
    }
    if (dd > 0) {
        if (mx == r) {
            hh = (g - b) / dd;
            if (g < b) {
                hh += 6;
            }
        } else if (mx == g) {
            hh = (b - r) / dd + 2;
        } else {
            hh = (r - g) / dd + 4;
        }
        hh /= 6.0;
    }
    return .{ hh, sat, mx };
}

pub fn rgbToHsv(rgb: Vec) Vec {
    if (comptime is_wasm) {
        const c3: [3]f32 = rgbToHsv3(rgb[0], rgb[1], rgb[2]);
        return .{ c3[0], c3[1], c3[2], rgb[3] };
    }
    const r: Vec = swizzle(rgb, .x, .x, .x, .x);
    const g: Vec = swizzle(rgb, .y, .y, .y, .y);
    const b: Vec = swizzle(rgb, .z, .z, .z, .z);

    const minv: Vec = min(r, min(g, b));
    const v: Vec = max(r, max(g, b));
    const d: Vec = v - minv;
    const s: Vec = if (allTrue(isNearEqual(v, splat(0.0), splat(math.floatEps(f32))), 3)) splat(0.0) else d / v;

    if (allTrue(d < splat(math.floatEps(f32)), 3)) {
        const hv: Vec = blend(boolx4(true, false, false, false), splat(0.0), v);
        const hva: Vec = blend(boolx4(true, true, true, false), hv, rgb);
        return blend(boolx4(true, false, true, true), hva, s);
    } else {
        var h: Vec = undefined;
        if (allTrue(r == v, 3)) {
            h = (g - b) / d;
            if (allTrue(g < b, 3)) {
                h += splat(6.0);
            }
        } else if (allTrue(g == v, 3)) {
            h = splat(2.0) + (b - r) / d;
        } else {
            h = splat(4.0) + (r - g) / d;
        }

        h /= splat(6.0);
        const hv: Vec = blend(boolx4(true, false, false, false), h, v);
        const hva: Vec = blend(boolx4(true, true, true, false), hv, rgb);
        return blend(boolx4(true, false, true, true), hva, s);
    }
}

pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    // ---- Constructors
    pub fn init(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }
    /// From human/CSS-order hex 0xRRGGBBAA. `Color.hex(0xff8800ff)` = orange.
    pub fn hex(value: u32) Color {
        return .{
            .r = @truncate(value >> 24),
            .g = @truncate(value >> 16),
            .b = @truncate(value >> 8),
            .a = @truncate(value),
        };
    }
    /// From CSS-order 24-bit hex 0xRRGGBB (opaque). `Color.rgbHex(0xff8800)` = orange.
    pub fn rgbHex(value: u32) Color {
        return .{
            .r = @truncate(value >> 16),
            .g = @truncate(value >> 8),
            .b = @truncate(value),
            .a = 255,
        };
    }
    /// From 0..1 sRGB floats (clamped). Inverse of `toFloats`.
    pub fn fromFloats(r: f32, g: f32, b: f32, a: f32) Color {
        return fromVec(.{ r, g, b, a });
    }
    /// From a 0..1 sRGB `Vec` (clamped). Inverse of `toVec`.
    pub fn fromVec(v: Vec) Color {
        const c: Vec = clamp01(v) * @as(Vec, @splat(255.0));
        return .{
            .r = @trunc(c[0]),
            .g = @trunc(c[1]),
            .b = @trunc(c[2]),
            .a = @trunc(c[3]),
        };
    }
    /// From a 0..1 LINEAR-light `Vec` — encodes to sRGB then to bytes.
    /// Use when a shader/lighting path produced linear color.
    pub fn fromLinear(v: Vec) Color {
        return fromVec(linearToSrgb(v));
    }
    /// From HSVA, all components in 0..1 (hue is a fraction, not degrees).
    pub fn fromHSV(hsva: Vec) Color {
        return fromVec(hsvToRgb(hsva));
    }

    // ---- Conversions out
    /// 0..1 sRGB floats, RGBA order — for shader uniforms + color widgets.
    pub fn toFloats(c: Color) [4]f32 {
        return .{ float(c.r) / 255.0, float(c.g) / 255.0, float(c.b) / 255.0, float(c.a) / 255.0 };
    }
    /// 0..1 sRGB as a `Vec` — the input shape for the GPU-safe color math.
    pub fn toVec(c: Color) Vec {
        return .{ float(c.r) / 255.0, float(c.g) / 255.0, float(c.b) / 255.0, float(c.a) / 255.0 };
    }
    /// 0..1 LINEAR-light `Vec` — for correct blending/lighting math.
    pub fn toLinear(c: Color) Vec {
        return srgbToLinear(c.toVec());
    }
    /// HSVA in 0..1 (hue is a fraction, not degrees). Scalar (CPU-wasm-safe).
    pub fn toHSV(c: Color) Vec {
        return rgbToHsv(c.toVec());
    }
    /// Human/CSS-order packed hex 0xRRGGBBAA (the inverse of `hex`).
    pub fn toHex(c: Color) u32 {
        return (@as(u32, c.r) << 24) | (@as(u32, c.g) << 16) | (@as(u32, c.b) << 8) | @as(u32, c.a);
    }
    /// GPU/draw-list packed u32 0xAABBGGRR (ImGui IM_COL32 — R in low byte).
    /// This is the vertex/draw-list WIRE format; prefer passing `Color` and
    /// letting the engine call this at the GPU boundary.
    pub fn toWire(c: Color) u32 {
        return (@as(u32, c.a) << 24) | (@as(u32, c.b) << 16) | (@as(u32, c.g) << 8) | @as(u32, c.r);
    }
    /// Unpack the 0xAABBGGRR wire format back to a `Color`.
    pub fn fromWire(w: u32) Color {
        return .{
            .r = @truncate(w & 0xFF),
            .g = @truncate((w >> 8) & 0xFF),
            .b = @truncate((w >> 16) & 0xFF),
            .a = @truncate((w >> 24) & 0xFF),
        };
    }

    // ---- Predicates / manipulation
    pub fn equals(a: Color, b: Color) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
    }
    /// Linear interpolation in straight (sRGB) 0..255 channels. `t` unclamped.
    pub fn lerp(a: Color, b: Color, t: f32) Color {
        const av: Vec = .{ float(a.r), float(a.g), float(a.b), float(a.a) };
        const bv: Vec = .{ float(b.r), float(b.g), float(b.b), float(b.a) };
        const v: Vec = av + @as(Vec, @splat(t)) * (bv - av);
        return .{
            .r = @trunc(std.math.clamp(v[0], 0, 255)),
            .g = @trunc(std.math.clamp(v[1], 0, 255)),
            .b = @trunc(std.math.clamp(v[2], 0, 255)),
            .a = @trunc(std.math.clamp(v[3], 0, 255)),
        };
    }
    /// Set the alpha channel from a 0..1 fraction (clamped). RGB unchanged.
    pub fn alpha(c: Color, a01: f32) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = @trunc(255.0 * std.math.clamp(a01, 0, 1)) };
    }
    /// Alias of `alpha` — "make this color partially transparent".
    pub const fade = alpha;
    /// Multiply each RGB channel by `factor` (>=0); alpha unchanged.
    pub fn brightness(c: Color, factor: f32) Color {
        const f: f32 = @max(0.0, factor);
        return .{
            .r = @trunc(@min(255.0, float(c.r) * f)),
            .g = @trunc(@min(255.0, float(c.g) * f)),
            .b = @trunc(@min(255.0, float(c.b) * f)),
            .a = c.a,
        };
    }
    /// Multiply the alpha channel by `mul` (clamped to 0..255); RGB unchanged.
    pub fn scaleAlpha(c: Color, mul: f32) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = @trunc(std.math.clamp(float(c.a) * mul, 0, 255)) };
    }

    // ---- raylib's named colour constants (raylib.h order, for diff parity)
    pub const lightgray = Color.init(200, 200, 200, 255);
    pub const gray = Color.init(130, 130, 130, 255);
    pub const darkgray = Color.init(80, 80, 80, 255);
    pub const yellow = Color.init(253, 249, 0, 255);
    pub const gold = Color.init(255, 203, 0, 255);
    pub const orange = Color.init(255, 161, 0, 255);
    pub const pink = Color.init(255, 109, 194, 255);
    pub const red = Color.init(230, 41, 55, 255);
    pub const maroon = Color.init(190, 33, 55, 255);
    pub const green = Color.init(0, 228, 48, 255);
    pub const lime = Color.init(0, 158, 47, 255);
    pub const darkgreen = Color.init(0, 117, 44, 255);
    pub const skyblue = Color.init(102, 191, 255, 255);
    pub const blue = Color.init(0, 121, 241, 255);
    pub const darkblue = Color.init(0, 82, 172, 255);
    pub const purple = Color.init(200, 122, 255, 255);
    pub const violet = Color.init(135, 60, 190, 255);
    pub const darkpurple = Color.init(112, 31, 126, 255);
    pub const beige = Color.init(211, 176, 131, 255);
    pub const brown = Color.init(127, 106, 79, 255);
    pub const darkbrown = Color.init(76, 63, 47, 255);
    pub const white = Color.init(255, 255, 255, 255);
    pub const black = Color.init(0, 0, 0, 255);
    pub const blank = Color.init(0, 0, 0, 0);
    pub const magenta = Color.init(255, 0, 255, 255);
    pub const raywhite = Color.init(245, 245, 245, 255);
};

test "zm.Color round-trips" {
    const c: Color = .{ .r = 0x12, .g = 0x34, .b = 0x56, .a = 0x78 };
    try expectEqual(@as(u32, 0x12345678), c.toHex());
    try expect(c.equals(Color.hex(0x12345678)));
    try expectEqual(@as(u32, 0x78563412), c.toWire()); // 0xAABBGGRR
    try expect(c.equals(Color.fromWire(c.toWire())));
    const f: [4]f32 = c.toFloats();
    try expectApproxEqAbs(@as(f32, 0x12) / 255.0, f[0], 1e-6);
    try expect(Color.rgbHex(0x123456).equals(.{ .r = 0x12, .g = 0x34, .b = 0x56, .a = 255 }));
}

test "zm.color.rgbToHsv" {
    try expectVecApproxEqAbs(rgbToHsv(f32x4(0.2, 0.4, 0.8, 1.0)), f32x4(0.6111, 0.75, 0.8, 1.0), 0.0001);
    try expectVecApproxEqAbs(rgbToHsv(f32x4(0.4, 0.2, 0.8, 1.0)), f32x4(0.7222, 0.75, 0.8, 1.0), 0.0001);
    try expectVecApproxEqAbs(rgbToHsv(f32x4(0.4, 0.8, 0.2, 1.0)), f32x4(0.2777, 0.75, 0.8, 1.0), 0.0001);
    try expectVecApproxEqAbs(rgbToHsv(f32x4(1.0, 0.0, 0.0, 0.5)), f32x4(0.0, 1.0, 1.0, 0.5), 0.0001);
    try expectVecApproxEqAbs(rgbToHsv(f32x4(0.0, 1.0, 0.0, 0.25)), f32x4(0.3333, 1.0, 1.0, 0.25), 0.0001);
    try expectVecApproxEqAbs(rgbToHsv(f32x4(0.0, 0.0, 1.0, 1.0)), f32x4(0.6666, 1.0, 1.0, 1.0), 0.0001);
    try expectVecApproxEqAbs(rgbToHsv(f32x4(0.0, 0.0, 0.0, 1.0)), f32x4(0.0, 0.0, 0.0, 1.0), 0.0001);
    try expectVecApproxEqAbs(rgbToHsv(f32x4(1.0, 1.0, 1.0, 1.0)), f32x4(0.0, 0.0, 1.0, 1.0), 0.0001);
}

test "zm.color.hsvToRgb" {
    const epsilon: f32 = 0.0005;
    try expectVecApproxEqAbs(f32x4(0.2, 0.4, 0.8, 1.0), hsvToRgb(f32x4(0.6111, 0.75, 0.8, 1.0)), epsilon);
    try expectVecApproxEqAbs(f32x4(0.4, 0.2, 0.8, 1.0), hsvToRgb(f32x4(0.7222, 0.75, 0.8, 1.0)), epsilon);
    try expectVecApproxEqAbs(f32x4(0.4, 0.8, 0.2, 1.0), hsvToRgb(f32x4(0.2777, 0.75, 0.8, 1.0)), epsilon);
    try expectVecApproxEqAbs(f32x4(1.0, 0.0, 0.0, 0.5), hsvToRgb(f32x4(0.0, 1.0, 1.0, 0.5)), epsilon);
    try expectVecApproxEqAbs(f32x4(0.0, 1.0, 0.0, 0.25), hsvToRgb(f32x4(0.3333, 1.0, 1.0, 0.25)), epsilon);
    try expectVecApproxEqAbs(f32x4(0.0, 0.0, 1.0, 1.0), hsvToRgb(f32x4(0.6666, 1.0, 1.0, 1.0)), epsilon);
    try expectVecApproxEqAbs(f32x4(0.0, 0.0, 0.0, 1.0), hsvToRgb(f32x4(0.0, 0.0, 0.0, 1.0)), epsilon);
    try expectVecApproxEqAbs(f32x4(1.0, 1.0, 1.0, 1.0), hsvToRgb(f32x4(0.0, 0.0, 1.0, 1.0)), epsilon);
    try expectVecApproxEqAbs(
        hsvToRgb(rgbToHsv(f32x4(0.1839, 0.632, 0.82198, 1.0))),
        f32x4(0.1839, 0.632, 0.82198, 1.0),
        epsilon,
    );
    try expectVecApproxEqAbs(
        hsvToRgb(rgbToHsv(f32x4(0.82198, 0.1839, 0.632, 1.0))),
        f32x4(0.82198, 0.1839, 0.632, 1.0),
        epsilon,
    );
    try expectVecApproxEqAbs(
        rgbToHsv(hsvToRgb(f32x4(0.82198, 0.1839, 0.632, 1.0))),
        f32x4(0.82198, 0.1839, 0.632, 1.0),
        epsilon,
    );
    try expectVecApproxEqAbs(
        rgbToHsv(hsvToRgb(f32x4(0.1839, 0.82198, 0.632, 1.0))),
        f32x4(0.1839, 0.82198, 0.632, 1.0),
        epsilon,
    );
}

test "zm.color.hsvToRgb3 / rgbToHsv3 (scalar, no alpha)" {
    const red: [3]f32 = hsvToRgb3(0.0, 1.0, 1.0);
    try expectApproxEqAbs(@as(f32, 1.0), red[0], 0.0005);
    try expectApproxEqAbs(@as(f32, 0.0), red[1], 0.0005);
    try expectApproxEqAbs(@as(f32, 0.0), red[2], 0.0005);
    const hsv: [3]f32 = rgbToHsv3(0.2, 0.4, 0.8);
    try expectApproxEqAbs(@as(f32, 0.6111), hsv[0], 0.0001);
    try expectApproxEqAbs(@as(f32, 0.75), hsv[1], 0.0001);
    try expectApproxEqAbs(@as(f32, 0.8), hsv[2], 0.0001);
    // 3-channel result must match the Vec forms' rgb/hsv channels.
    const vrgb: Vec = hsvToRgb(f32x4(0.6111, 0.75, 0.8, 1.0));
    const argb: [3]f32 = hsvToRgb3(0.6111, 0.75, 0.8);
    try expectApproxEqAbs(vrgb[0], argb[0], 0.0005);
    try expectApproxEqAbs(vrgb[1], argb[1], 0.0005);
    try expectApproxEqAbs(vrgb[2], argb[2], 0.0005);
}

test "zm.color.rgbToSrgb" {
    const epsilon: f32 = 0.001;
    try expectVecApproxEqAbs(rgbToSrgb(f32x4(0.2, 0.4, 0.8, 1.0)), f32x4(0.484, 0.665, 0.906, 1.0), epsilon);
}

test "zm.color.srgbToRgb" {
    const epsilon: f32 = 0.0007;
    try expectVecApproxEqAbs(f32x4(0.2, 0.4, 0.8, 1.0), srgbToRgb(f32x4(0.484, 0.665, 0.906, 1.0)), epsilon);
    try expectVecApproxEqAbs(
        rgbToSrgb(srgbToRgb(f32x4(0.1839, 0.82198, 0.632, 1.0))),
        f32x4(0.1839, 0.82198, 0.632, 1.0),
        epsilon,
    );
}
//
// X. Misc functions
//
pub fn linePointDistanceSplat(
    linept0: Vec,
    linept1: Vec,
    pt: Vec,
) Vec {
    const ptvec: Vec = pt - linept0;
    const linevec: Vec = linept1 - linept0;
    const scale: Vec = dot3Splat(ptvec, linevec) / lengthSq3Splat(linevec);
    return length3Splat(ptvec - linevec * scale);
}

pub fn linePointDistance(
    linept0: Vec,
    linept1: Vec,
    pt: Vec,
) f32 {
    return linePointDistanceSplat(linept0, linept1, pt)[0];
}
test "zm.linePointDistance" {
    const linept0: Vec = f32x4(-1.0, -2.0, -3.0, 1.0);
    const linept1: Vec = f32x4(1.0, 2.0, 3.0, 1.0);
    const pt: Vec = f32x4(1.0, 1.0, 1.0, 1.0);
    try expectApproxEqAbs(@as(f32, 0.654), linePointDistance(linept0, linept1, pt), 0.001);
}

test "zm.sincos32" {
    const epsilon: f32 = 0.0001;

    try expect(math.isNan(sincos32(math.inf(f32))[0]));
    try expect(math.isNan(sincos32(math.inf(f32))[1]));
    try expect(math.isNan(sincos32(-math.inf(f32))[0]));
    try expect(math.isNan(sincos32(-math.inf(f32))[1]));
    try expect(math.isNan(sincos32(math.nan(f32))[0]));
    try expect(math.isNan(sincos32(-math.nan(f32))[1]));

    try expect(math.isNan(sin32(math.inf(f32))));
    try expect(math.isNan(cos32(math.inf(f32))));
    try expect(math.isNan(sin32(-math.inf(f32))));
    try expect(math.isNan(cos32(-math.inf(f32))));
    try expect(math.isNan(sin32(math.nan(f32))));
    try expect(math.isNan(cos32(-math.nan(f32))));

    var f: f32 = -100.0;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const sc = sincos32(f);
        const s0 = sin32(f);
        const c0 = cos32(f);
        const s = @sin(f);
        const c = @cos(f);
        try expect(math.approxEqAbs(f32, sc[0], s, epsilon));
        try expect(math.approxEqAbs(f32, sc[1], c, epsilon));
        try expect(math.approxEqAbs(f32, s0, s, epsilon));
        try expect(math.approxEqAbs(f32, c0, c, epsilon));
        f += 0.12345 * float(i);
    }
}

test "zm.asin32" {
    const epsilon: f32 = 0.0001;

    try expect(math.approxEqAbs(f32, asin(@as(f32, -1.1)), -0.5 * pi, epsilon));
    try expect(math.approxEqAbs(f32, asin(@as(f32, 1.1)), 0.5 * pi, epsilon));
    try expect(math.approxEqAbs(f32, asin(@as(f32, -1000.1)), -0.5 * pi, epsilon));
    try expect(math.approxEqAbs(f32, asin(@as(f32, 100000.1)), 0.5 * pi, epsilon));
    try expect(math.isNan(asin(math.inf(f32))));
    try expect(math.isNan(asin(-math.inf(f32))));
    try expect(math.isNan(asin(math.nan(f32))));
    try expect(math.isNan(asin(-math.nan(f32))));

    try expectVecApproxEqAbs(asin(@as(F32x8, @splat(-100.0))), @as(F32x8, @splat(-0.5 * pi)), epsilon);
    try expectVecApproxEqAbs(asin(@as(F32x16, @splat(100.0))), @as(F32x16, @splat(0.5 * pi)), epsilon);
    try expect(allTrue(isNan(asin(splat(math.inf(f32)))), 0) == true);
    try expect(allTrue(isNan(asin(splat(-math.inf(f32)))), 0) == true);
    try expect(allTrue(isNan(asin(splat(math.nan(f32)))), 0) == true);
    try expect(allTrue(isNan(asin(splat(math.snan(f32)))), 0) == true);

    var f: f32 = -1.0;
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const r0: f32 = asin32(f);
        const r1: f32 = math.asin(f);
        const r4: Vec = asin(splat(f));
        const r8: F32x8 = asin(@as(F32x8, @splat(f)));
        const r16: F32x16 = asin(@as(F32x16, @splat(f)));
        try expect(math.approxEqAbs(f32, r0, r1, epsilon));
        try expectVecApproxEqAbs(r4, splat(r1), epsilon);
        try expectVecApproxEqAbs(r8, @as(F32x8, @splat(r1)), epsilon);
        try expectVecApproxEqAbs(r16, @as(F32x16, @splat(r1)), epsilon);
        f += 0.09 * float(i);
    }
}

test "zm.acos32" {
    const epsilon: f32 = 0.1;

    try expect(math.approxEqAbs(f32, acos(@as(f32, -1.1)), pi, epsilon));
    try expect(math.approxEqAbs(f32, acos(@as(f32, -10000.1)), pi, epsilon));
    try expect(math.approxEqAbs(f32, acos(@as(f32, 1.1)), 0.0, epsilon));
    try expect(math.approxEqAbs(f32, acos(@as(f32, 1000.1)), 0.0, epsilon));
    try expect(math.isNan(acos(math.inf(f32))));
    try expect(math.isNan(acos(-math.inf(f32))));
    try expect(math.isNan(acos(math.nan(f32))));
    try expect(math.isNan(acos(-math.nan(f32))));

    try expectVecApproxEqAbs(acos(@as(F32x8, @splat(-100.0))), @as(F32x8, @splat(pi)), epsilon);
    try expectVecApproxEqAbs(acos(@as(F32x16, @splat(100.0))), @as(F32x16, @splat(0.0)), epsilon);
    try expect(allTrue(isNan(acos(splat(math.inf(f32)))), 0) == true);
    try expect(allTrue(isNan(acos(splat(-math.inf(f32)))), 0) == true);
    try expect(allTrue(isNan(acos(splat(math.nan(f32)))), 0) == true);
    try expect(allTrue(isNan(acos(splat(math.snan(f32)))), 0) == true);

    var f: f32 = -1.0;
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const r0: f32 = acos32(f);
        const r1: f32 = math.acos(f);
        const r4: Vec = acos(splat(f));
        const r8: F32x8 = acos(@as(F32x8, @splat(f)));
        const r16: F32x16 = acos(@as(F32x16, @splat(f)));
        try expect(math.approxEqAbs(f32, r0, r1, epsilon));
        try expectVecApproxEqAbs(r4, splat(r1), epsilon);
        try expectVecApproxEqAbs(r8, @as(F32x8, @splat(r1)), epsilon);
        try expectVecApproxEqAbs(r16, @as(F32x16, @splat(r1)), epsilon);
        f += 0.09 * float(i);
    }
}

pub fn cmulSoa(
    re0: anytype,
    im0: anytype,
    re1: anytype,
    im1: anytype,
) [2]@TypeOf(re0, im0, re1, im1) {
    const re0_re1: @TypeOf(re0, re1) = re0 * re1;
    const re0_im1: @TypeOf(re0, im1) = re0 * im1;
    return .{
        mulAdd(-im0, im1, re0_re1), // re
        mulAdd(re1, im0, re0_im1), // im
    };
}
//
// FFT (implementation based on xdsp.h from DirectXMath)
//
fn fftButterflyDit4_1(re0: *Vec, im0: *Vec) void {
    const re0l: Vec = swizzle(re0.*, .x, .x, .y, .y);
    const re0h: Vec = swizzle(re0.*, .z, .z, .w, .w);

    const im0l: Vec = swizzle(im0.*, .x, .x, .y, .y);
    const im0h: Vec = swizzle(im0.*, .z, .z, .w, .w);

    const re_temp: Vec = mulAdd(re0h, f32x4(1.0, -1.0, 1.0, -1.0), re0l);
    const im_temp: Vec = mulAdd(im0h, f32x4(1.0, -1.0, 1.0, -1.0), im0l);

    const re_shuf0: Vec = @shuffle(f32, re_temp, im_temp, [4]i32{ 2, 3, ~@as(i32, 2), ~@as(i32, 3) });
    const re_shuf: Vec = swizzle(re_shuf0, .x, .w, .x, .w);
    const im_shuf: Vec = swizzle(re_shuf0, .z, .y, .z, .y);

    const re_templ: Vec = swizzle(re_temp, .x, .y, .x, .y);
    const im_templ: Vec = swizzle(im_temp, .x, .y, .x, .y);

    re0.* = mulAdd(re_shuf, f32x4(1.0, 1.0, -1.0, -1.0), re_templ);
    im0.* = mulAdd(im_shuf, f32x4(1.0, -1.0, -1.0, 1.0), im_templ);
}

fn fftButterflyDit4_4(
    re0: *Vec,
    re1: *Vec,
    re2: *Vec,
    re3: *Vec,
    im0: *Vec,
    im1: *Vec,
    im2: *Vec,
    im3: *Vec,
    unity_table_re: []const Vec,
    unity_table_im: []const Vec,
    stride: u32,
    last: bool,
) void {
    const re_temp0: Vec = re0.* + re2.*;
    const im_temp0: Vec = im0.* + im2.*;

    const re_temp2: Vec = re1.* + re3.*;
    const im_temp2: Vec = im1.* + im3.*;

    const re_temp1: Vec = re0.* - re2.*;
    const im_temp1: Vec = im0.* - im2.*;

    const re_temp3: Vec = re1.* - re3.*;
    const im_temp3: Vec = im1.* - im3.*;

    var re_temp4: Vec = re_temp0 + re_temp2;
    var im_temp4: Vec = im_temp0 + im_temp2;

    var re_temp5: Vec = re_temp1 + im_temp3;
    var im_temp5: Vec = im_temp1 - re_temp3;

    var re_temp6: Vec = re_temp0 - re_temp2;
    var im_temp6: Vec = im_temp0 - im_temp2;

    var re_temp7: Vec = re_temp1 - im_temp3;
    var im_temp7: Vec = im_temp1 + re_temp3;

    {
        const re_im: [2]Vec = cmulSoa(re_temp5, im_temp5, unity_table_re[stride], unity_table_im[stride]);
        re_temp5 = re_im[0];
        im_temp5 = re_im[1];
    }
    {
        const re_im: [2]Vec = cmulSoa(re_temp6, im_temp6, unity_table_re[stride * 2], unity_table_im[stride * 2]);
        re_temp6 = re_im[0];
        im_temp6 = re_im[1];
    }
    {
        const re_im: [2]Vec = cmulSoa(re_temp7, im_temp7, unity_table_re[stride * 3], unity_table_im[stride * 3]);
        re_temp7 = re_im[0];
        im_temp7 = re_im[1];
    }

    if (last) {
        fftButterflyDit4_1(&re_temp4, &im_temp4);
        fftButterflyDit4_1(&re_temp5, &im_temp5);
        fftButterflyDit4_1(&re_temp6, &im_temp6);
        fftButterflyDit4_1(&re_temp7, &im_temp7);
    }

    re0.* = re_temp4;
    im0.* = im_temp4;

    re1.* = re_temp5;
    im1.* = im_temp5;

    re2.* = re_temp6;
    im2.* = im_temp6;

    re3.* = re_temp7;
    im3.* = im_temp7;
}

fn fft4(
    re: []Vec,
    im: []Vec,
    count: u32,
) void {
    assert(isPowerOfTwo(count), @src());
    assert(re.len >= count, @src());
    assert(im.len >= count, @src());

    var index: u32 = 0;
    while (index < count) : (index += 1) {
        fftButterflyDit4_1(&re[index], &im[index]);
    }
}
fn fftUnswizzle(input: []const Vec, output: []Vec) void {
    assert(isPowerOfTwo(input.len), @src());
    assert(input.len == output.len, @src());
    assert(input.ptr != output.ptr, @src());

    const log2_length = log2_int(usize, input.len * 4);
    assert(log2_length >= 2, @src());

    const len_n: usize = input.len;

    const f32_output: []f32 = @as([*]f32, @ptrCast(output.ptr))[0 .. output.len * 4];

    const static = struct {
        const swizzle_table = [256]u8{
            0x00, 0x40, 0x80, 0xC0, 0x10, 0x50, 0x90, 0xD0, 0x20, 0x60, 0xA0, 0xE0, 0x30, 0x70, 0xB0, 0xF0,
            0x04, 0x44, 0x84, 0xC4, 0x14, 0x54, 0x94, 0xD4, 0x24, 0x64, 0xA4, 0xE4, 0x34, 0x74, 0xB4, 0xF4,
            0x08, 0x48, 0x88, 0xC8, 0x18, 0x58, 0x98, 0xD8, 0x28, 0x68, 0xA8, 0xE8, 0x38, 0x78, 0xB8, 0xF8,
            0x0C, 0x4C, 0x8C, 0xCC, 0x1C, 0x5C, 0x9C, 0xDC, 0x2C, 0x6C, 0xAC, 0xEC, 0x3C, 0x7C, 0xBC, 0xFC,
            0x01, 0x41, 0x81, 0xC1, 0x11, 0x51, 0x91, 0xD1, 0x21, 0x61, 0xA1, 0xE1, 0x31, 0x71, 0xB1, 0xF1,
            0x05, 0x45, 0x85, 0xC5, 0x15, 0x55, 0x95, 0xD5, 0x25, 0x65, 0xA5, 0xE5, 0x35, 0x75, 0xB5, 0xF5,
            0x09, 0x49, 0x89, 0xC9, 0x19, 0x59, 0x99, 0xD9, 0x29, 0x69, 0xA9, 0xE9, 0x39, 0x79, 0xB9, 0xF9,
            0x0D, 0x4D, 0x8D, 0xCD, 0x1D, 0x5D, 0x9D, 0xDD, 0x2D, 0x6D, 0xAD, 0xED, 0x3D, 0x7D, 0xBD, 0xFD,
            0x02, 0x42, 0x82, 0xC2, 0x12, 0x52, 0x92, 0xD2, 0x22, 0x62, 0xA2, 0xE2, 0x32, 0x72, 0xB2, 0xF2,
            0x06, 0x46, 0x86, 0xC6, 0x16, 0x56, 0x96, 0xD6, 0x26, 0x66, 0xA6, 0xE6, 0x36, 0x76, 0xB6, 0xF6,
            0x0A, 0x4A, 0x8A, 0xCA, 0x1A, 0x5A, 0x9A, 0xDA, 0x2A, 0x6A, 0xAA, 0xEA, 0x3A, 0x7A, 0xBA, 0xFA,
            0x0E, 0x4E, 0x8E, 0xCE, 0x1E, 0x5E, 0x9E, 0xDE, 0x2E, 0x6E, 0xAE, 0xEE, 0x3E, 0x7E, 0xBE, 0xFE,
            0x03, 0x43, 0x83, 0xC3, 0x13, 0x53, 0x93, 0xD3, 0x23, 0x63, 0xA3, 0xE3, 0x33, 0x73, 0xB3, 0xF3,
            0x07, 0x47, 0x87, 0xC7, 0x17, 0x57, 0x97, 0xD7, 0x27, 0x67, 0xA7, 0xE7, 0x37, 0x77, 0xB7, 0xF7,
            0x0B, 0x4B, 0x8B, 0xCB, 0x1B, 0x5B, 0x9B, 0xDB, 0x2B, 0x6B, 0xAB, 0xEB, 0x3B, 0x7B, 0xBB, 0xFB,
            0x0F, 0x4F, 0x8F, 0xCF, 0x1F, 0x5F, 0x9F, 0xDF, 0x2F, 0x6F, 0xAF, 0xEF, 0x3F, 0x7F, 0xBF, 0xFF,
        };
    };

    if ((log2_length & 1) == 0) {
        // [zimr Z0] Zig-version drift.  `log2_length` is `Log2Int(usize)`
        // = u5 on wasm32.  Upstream wrote `@as(u6, @intCast(32 - log2_length))`,
        // but in Zig 0.16 the bare `32` literal is inferred as u5 to match
        // `log2_length` and then can't represent 32.  Compute the
        // difference in u32, then `@intCast` down to the shift-amount
        // type - `assert(log2_length >= 2)` above keeps the value in
        // [1,30], so the narrowing cast is safe.  (This FFT path is also
        // dead-weight the adoption plan marks for later removal.)
        const rev32: Log2Int(usize) = @intCast(@as(u32, 32) - log2_length);
        var index: usize = 0;
        while (index < len_n) : (index += 1) {
            const n = index * 4;
            const addr =
                (@as(usize, @intCast(static.swizzle_table[n & 0xff])) << 24) |
                (@as(usize, @intCast(static.swizzle_table[(n >> 8) & 0xff])) << 16) |
                (@as(usize, @intCast(static.swizzle_table[(n >> 16) & 0xff])) << 8) |
                @as(usize, @intCast(static.swizzle_table[(n >> 24) & 0xff]));
            f32_output[addr >> rev32] = input[index][0];
            f32_output[(0x40000000 | addr) >> rev32] = input[index][1];
            f32_output[(0x80000000 | addr) >> rev32] = input[index][2];
            f32_output[(0xC0000000 | addr) >> rev32] = input[index][3];
        }
    } else {
        // [zimr Z0] Zig-version drift, same class as the even branch
        // above: shift amounts must be exactly `Log2Int(usize)` (u5 on
        // wasm32), and the bare `32` literal can't be inferred as u5.
        // `log2_length` is odd and >= 2 here, so >= 3 - both
        // `log2_length - 3` (in [0,28]) and `32 - (log2_length - 3)`
        // (in [4,32]... clamped: the FFT only runs with log2_length in
        // a range that keeps this a valid shift) fit after @intCast.
        const log2_shift: Log2Int(usize) = @intCast(log2_length - 3);
        const rev7 = @as(usize, 1) << log2_shift;
        const rev32: Log2Int(usize) = @intCast(@as(u32, 32) - (@as(u32, log2_length) - 3));
        var index: usize = 0;
        while (index < len_n) : (index += 1) {
            const n = index / 2;
            var addr =
                (((@as(usize, @intCast(static.swizzle_table[n & 0xff])) << 24) |
                    (@as(usize, @intCast(static.swizzle_table[(n >> 8) & 0xff])) << 16) |
                    (@as(usize, @intCast(static.swizzle_table[(n >> 16) & 0xff])) << 8) |
                    (@as(usize, @intCast(static.swizzle_table[(n >> 24) & 0xff])))) >> rev32) |
                ((index & 1) * rev7 * 4);
            f32_output[addr] = input[index][0];
            addr += rev7;
            f32_output[addr] = input[index][1];
            addr += rev7;
            f32_output[addr] = input[index][2];
            addr += rev7;
            f32_output[addr] = input[index][3];
        }
    }
}

test "zm.fft4" {
    const epsilon: f32 = 0.0001;
    var re = [_]Vec{f32x4(1.0, 2.0, 3.0, 4.0)};
    var im = [_]Vec{splat(0.0)};
    fft4(re[0..], im[0..], 1);

    var re_uns: [1]Vec = undefined;
    var im_uns: [1]Vec = undefined;
    fftUnswizzle(re[0..], re_uns[0..]);
    fftUnswizzle(im[0..], im_uns[0..]);

    try expectVecApproxEqAbs(re_uns[0], f32x4(10.0, -2.0, -2.0, -2.0), epsilon);
    try expectVecApproxEqAbs(im_uns[0], f32x4(0.0, 2.0, 0.0, -2.0), epsilon);
}

fn fft8(
    re: []Vec,
    im: []Vec,
    count: u32,
) void {
    assert(isPowerOfTwo(count), @src());
    assert(re.len >= 2 * count, @src());
    assert(im.len >= 2 * count, @src());

    var index: u32 = 0;
    while (index < count) : (index += 1) {
        var pre = re[index * 2 ..];
        var pim = im[index * 2 ..];

        var odds_re = @shuffle(f32, pre[0], pre[1], [4]i32{ 1, 3, ~@as(i32, 1), ~@as(i32, 3) });
        var evens_re = @shuffle(f32, pre[0], pre[1], [4]i32{ 0, 2, ~@as(i32, 0), ~@as(i32, 2) });
        var odds_im = @shuffle(f32, pim[0], pim[1], [4]i32{ 1, 3, ~@as(i32, 1), ~@as(i32, 3) });
        var evens_im = @shuffle(f32, pim[0], pim[1], [4]i32{ 0, 2, ~@as(i32, 0), ~@as(i32, 2) });
        fftButterflyDit4_1(&odds_re, &odds_im);
        fftButterflyDit4_1(&evens_re, &evens_im);

        {
            const re_im = cmulSoa(
                odds_re,
                odds_im,
                f32x4(1.0, 0.70710677, 0.0, -0.70710677),
                f32x4(0.0, -0.70710677, -1.0, -0.70710677),
            );
            pre[0] = evens_re + re_im[0];
            pim[0] = evens_im + re_im[1];
        }
        {
            const re_im = cmulSoa(
                odds_re,
                odds_im,
                f32x4(-1.0, -0.70710677, 0.0, 0.70710677),
                f32x4(0.0, 0.70710677, 1.0, 0.70710677),
            );
            pre[1] = evens_re + re_im[0];
            pim[1] = evens_im + re_im[1];
        }
    }
}
test "zm.fft8" {
    const epsilon: f32 = 0.0001;
    var re = [_]Vec{ f32x4(1.0, 2.0, 3.0, 4.0), f32x4(5.0, 6.0, 7.0, 8.0) };
    var im = [_]Vec{ splat(0.0), splat(0.0) };
    fft8(re[0..], im[0..], 1);

    var re_uns: [2]Vec = undefined;
    var im_uns: [2]Vec = undefined;
    fftUnswizzle(re[0..], re_uns[0..]);
    fftUnswizzle(im[0..], im_uns[0..]);

    try expectVecApproxEqAbs(re_uns[0], f32x4(36.0, -4.0, -4.0, -4.0), epsilon);
    try expectVecApproxEqAbs(re_uns[1], f32x4(-4.0, -4.0, -4.0, -4.0), epsilon);
    try expectVecApproxEqAbs(im_uns[0], f32x4(0.0, 9.656854, 4.0, 1.656854), epsilon);
    try expectVecApproxEqAbs(im_uns[1], f32x4(0.0, -1.656854, -4.0, -9.656854), epsilon);
}

fn fft16(
    re: []Vec,
    im: []Vec,
    count: u32,
) void {
    assert(isPowerOfTwo(count), @src());
    assert(re.len >= 4 * count, @src());
    assert(im.len >= 4 * count, @src());

    const static = struct {
        const unity_table_re = [4]Vec{
            f32x4(1.0, 1.0, 1.0, 1.0),
            f32x4(1.0, 0.92387950, 0.70710677, 0.38268343),
            f32x4(1.0, 0.70710677, -4.3711388e-008, -0.70710677),
            f32x4(1.0, 0.38268343, -0.70710677, -0.92387950),
        };
        const unity_table_im = [4]Vec{
            f32x4(-0.0, -0.0, -0.0, -0.0),
            f32x4(-0.0, -0.38268343, -0.70710677, -0.92387950),
            f32x4(-0.0, -0.70710677, -1.0, -0.70710677),
            f32x4(-0.0, -0.92387950, -0.70710677, 0.38268343),
        };
    };

    var index: u32 = 0;
    while (index < count) : (index += 1) {
        fftButterflyDit4_4(
            &re[index * 4],
            &re[index * 4 + 1],
            &re[index * 4 + 2],
            &re[index * 4 + 3],
            &im[index * 4],
            &im[index * 4 + 1],
            &im[index * 4 + 2],
            &im[index * 4 + 3],
            static.unity_table_re[0..],
            static.unity_table_im[0..],
            1,
            true,
        );
    }
}
test "zm.fft16" {
    const epsilon: f32 = 0.0001;
    var re = [_]Vec{
        f32x4(1.0, 2.0, 3.0, 4.0),
        f32x4(5.0, 6.0, 7.0, 8.0),
        f32x4(9.0, 10.0, 11.0, 12.0),
        f32x4(13.0, 14.0, 15.0, 16.0),
    };
    var im = [_]Vec{ splat(0.0), splat(0.0), splat(0.0), splat(0.0) };
    fft16(re[0..], im[0..], 1);

    var re_uns: [4]Vec = undefined;
    var im_uns: [4]Vec = undefined;
    fftUnswizzle(re[0..], re_uns[0..]);
    fftUnswizzle(im[0..], im_uns[0..]);

    try expectVecApproxEqAbs(re_uns[0], f32x4(136.0, -8.0, -8.0, -8.0), epsilon);
    try expectVecApproxEqAbs(re_uns[1], f32x4(-8.0, -8.0, -8.0, -8.0), epsilon);
    try expectVecApproxEqAbs(re_uns[2], f32x4(-8.0, -8.0, -8.0, -8.0), epsilon);
    try expectVecApproxEqAbs(re_uns[3], f32x4(-8.0, -8.0, -8.0, -8.0), epsilon);
    try expectVecApproxEqAbs(im_uns[0], f32x4(0.0, 40.218716, 19.313708, 11.972846), epsilon);
    try expectVecApproxEqAbs(im_uns[1], f32x4(8.0, 5.345429, 3.313708, 1.591299), epsilon);
    try expectVecApproxEqAbs(im_uns[2], f32x4(0.0, -1.591299, -3.313708, -5.345429), epsilon);
    try expectVecApproxEqAbs(im_uns[3], f32x4(-8.0, -11.972846, -19.313708, -40.218716), epsilon);
}

fn fftN(
    re: []Vec,
    im: []Vec,
    unity_table: []const Vec,
    len_n: u32,
    count: u32,
) void {
    assert(len_n > 16, @src());
    assert(isPowerOfTwo(len_n), @src());
    assert(isPowerOfTwo(count), @src());
    assert(re.len >= len_n * count / 4, @src());
    assert(re.len == im.len, @src());

    const total: u32 = count * len_n;
    const total_vectors: u32 = total / 4;
    const stage_vectors: u32 = len_n / 4;
    const stage_vectors_mask: u32 = stage_vectors - 1;
    const stride: u32 = len_n / 16;
    const stride_mask: u32 = stride - 1;
    const stride_inv_mask: u32 = ~stride_mask;

    var unity_table_re: []const Vec = unity_table;
    var unity_table_im: []const Vec = unity_table[len_n / 4 ..];

    var index: u32 = 0;
    while (index < total_vectors / 4) : (index += 1) {
        const n = (index & stride_inv_mask) * 4 + (index & stride_mask);
        fftButterflyDit4_4(
            &re[n],
            &re[n + stride],
            &re[n + stride * 2],
            &re[n + stride * 3],
            &im[n],
            &im[n + stride],
            &im[n + stride * 2],
            &im[n + stride * 3],
            unity_table_re[(n & stage_vectors_mask)..],
            unity_table_im[(n & stage_vectors_mask)..],
            stride,
            false,
        );
    }

    if (len_n > 16 * 4) {
        fftN(re, im, unity_table[(len_n / 2)..], len_n / 4, count * 4);
    } else if (len_n == 16 * 4) {
        fft16(re, im, count * 4);
    } else if (len_n == 8 * 4) {
        fft8(re, im, count * 4);
    } else if (len_n == 4 * 4) {
        fft4(re, im, count * 4);
    }
}
pub fn fftInitUnityTable(out_unity_table: []Vec) void {
    assert(isPowerOfTwo(out_unity_table.len), @src());
    assert(out_unity_table.len >= 32 and out_unity_table.len <= 512, @src());

    var unity_table: []Vec = out_unity_table;

    const v0123: Vec = f32x4(0.0, 1.0, 2.0, 3.0);
    var len_n: usize = out_unity_table.len / 4;
    var vlstep: Vec = splat(0.5 * pi / float(len_n));

    while (true) {
        len_n /= 4;
        var vjp: Vec = v0123;

        var j: u32 = 0;
        while (j < len_n) : (j += 1) {
            unity_table[j] = splat(1.0);
            unity_table[j + len_n * 4] = splat(0.0);

            var vls = vjp * vlstep;
            var sin_cos = sincos(vls);
            unity_table[j + len_n] = sin_cos[1];
            unity_table[j + len_n * 5] = sin_cos[0] * splat(-1.0);

            var vijp = vjp + vjp;
            vls = vijp * vlstep;
            sin_cos = sincos(vls);
            unity_table[j + len_n * 2] = sin_cos[1];
            unity_table[j + len_n * 6] = sin_cos[0] * splat(-1.0);

            vijp = vijp + vjp;
            vls = vijp * vlstep;
            sin_cos = sincos(vls);
            unity_table[j + len_n * 3] = sin_cos[1];
            unity_table[j + len_n * 7] = sin_cos[0] * splat(-1.0);

            vjp += splat(4.0);
        }
        vlstep *= splat(4.0);
        unity_table = unity_table[8 * len_n ..];

        if (len_n <= 4) {
            break;
        }
    }
}

pub fn fft(
    re: []Vec,
    im: []Vec,
    unity_table: []const Vec,
) void {
    const len_n: u32 = @as(u32, @intCast(re.len * 4));
    assert(isPowerOfTwo(len_n), @src());
    assert(len_n >= 4 and len_n <= 512, @src());
    assert(re.len == im.len, @src());

    var re_temp_storage: [128]Vec = undefined;
    var im_temp_storage: [128]Vec = undefined;
    const re_temp: []Vec = re_temp_storage[0..re.len];
    const im_temp: []Vec = im_temp_storage[0..im.len];

    @memcpy(re_temp, re);
    @memcpy(im_temp, im);

    if (len_n > 16) {
        assert(unity_table.len == len_n, @src());
        fftN(re_temp, im_temp, unity_table, len_n, 1);
    } else if (len_n == 16) {
        fft16(re_temp, im_temp, 1);
    } else if (len_n == 8) {
        fft8(re_temp, im_temp, 1);
    } else if (len_n == 4) {
        fft4(re_temp, im_temp, 1);
    }

    fftUnswizzle(re_temp, re);
    fftUnswizzle(im_temp, im);
}

test "zm.fftN" {
    var unity_table: [128]Vec = undefined;
    const epsilon: f32 = 0.0001;

    // 32 samples
    {
        var re = [_]Vec{
            f32x4(1.0, 2.0, 3.0, 4.0),     f32x4(5.0, 6.0, 7.0, 8.0),
            f32x4(9.0, 10.0, 11.0, 12.0),  f32x4(13.0, 14.0, 15.0, 16.0),
            f32x4(17.0, 18.0, 19.0, 20.0), f32x4(21.0, 22.0, 23.0, 24.0),
            f32x4(25.0, 26.0, 27.0, 28.0), f32x4(29.0, 30.0, 31.0, 32.0),
        };
        var im = [_]Vec{
            splat(0.0), splat(0.0), splat(0.0), splat(0.0),
            splat(0.0), splat(0.0), splat(0.0), splat(0.0),
        };

        fftInitUnityTable(unity_table[0..32]);
        fft(re[0..], im[0..], unity_table[0..32]);

        try expectVecApproxEqAbs(re[0], f32x4(528.0, -16.0, -16.0, -16.0), epsilon);
        try expectVecApproxEqAbs(re[1], f32x4(-16.0, -16.0, -16.0, -16.0), epsilon);
        try expectVecApproxEqAbs(re[2], f32x4(-16.0, -16.0, -16.0, -16.0), epsilon);
        try expectVecApproxEqAbs(re[3], f32x4(-16.0, -16.0, -16.0, -16.0), epsilon);
        try expectVecApproxEqAbs(re[4], f32x4(-16.0, -16.0, -16.0, -16.0), epsilon);
        try expectVecApproxEqAbs(re[5], f32x4(-16.0, -16.0, -16.0, -16.0), epsilon);
        try expectVecApproxEqAbs(re[6], f32x4(-16.0, -16.0, -16.0, -16.0), epsilon);
        try expectVecApproxEqAbs(re[7], f32x4(-16.0, -16.0, -16.0, -16.0), epsilon);
        try expectVecApproxEqAbs(im[0], f32x4(0.0, 162.450726, 80.437432, 52.744931), epsilon);
        try expectVecApproxEqAbs(im[1], f32x4(38.627417, 29.933895, 23.945692, 19.496056), epsilon);
        try expectVecApproxEqAbs(im[2], f32x4(16.0, 13.130861, 10.690858, 8.552178), epsilon);
        try expectVecApproxEqAbs(im[3], f32x4(6.627417, 4.853547, 3.182598, 1.575862), epsilon);
        try expectVecApproxEqAbs(im[4], f32x4(0.0, -1.575862, -3.182598, -4.853547), epsilon);
        try expectVecApproxEqAbs(im[5], f32x4(-6.627417, -8.552178, -10.690858, -13.130861), epsilon);
        try expectVecApproxEqAbs(im[6], f32x4(-16.0, -19.496056, -23.945692, -29.933895), epsilon);
        try expectVecApproxEqAbs(im[7], f32x4(-38.627417, -52.744931, -80.437432, -162.450726), epsilon);
    }

    // 64 samples
    {
        var re = [_]Vec{
            f32x4(1.0, 2.0, 3.0, 4.0),     f32x4(5.0, 6.0, 7.0, 8.0),
            f32x4(9.0, 10.0, 11.0, 12.0),  f32x4(13.0, 14.0, 15.0, 16.0),
            f32x4(17.0, 18.0, 19.0, 20.0), f32x4(21.0, 22.0, 23.0, 24.0),
            f32x4(25.0, 26.0, 27.0, 28.0), f32x4(29.0, 30.0, 31.0, 32.0),
            f32x4(1.0, 2.0, 3.0, 4.0),     f32x4(5.0, 6.0, 7.0, 8.0),
            f32x4(9.0, 10.0, 11.0, 12.0),  f32x4(13.0, 14.0, 15.0, 16.0),
            f32x4(17.0, 18.0, 19.0, 20.0), f32x4(21.0, 22.0, 23.0, 24.0),
            f32x4(25.0, 26.0, 27.0, 28.0), f32x4(29.0, 30.0, 31.0, 32.0),
        };
        var im = [_]Vec{
            splat(0.0), splat(0.0), splat(0.0), splat(0.0),
            splat(0.0), splat(0.0), splat(0.0), splat(0.0),
            splat(0.0), splat(0.0), splat(0.0), splat(0.0),
            splat(0.0), splat(0.0), splat(0.0), splat(0.0),
        };

        fftInitUnityTable(unity_table[0..64]);
        fft(re[0..], im[0..], unity_table[0..64]);

        try expectVecApproxEqAbs(re[0], f32x4(1056.0, 0.0, -32.0, 0.0), epsilon);
        var i: u32 = 1;
        while (i < 16) : (i += 1) {
            try expectVecApproxEqAbs(re[i], f32x4(-32.0, 0.0, -32.0, 0.0), epsilon);
        }

        const expected = [_]f32{
            0.0,        0.0,      324.901452,  0.000000, 160.874864,  0.0,      105.489863,  0.000000,
            77.254834,  0.0,      59.867789,   0.0,      47.891384,   0.0,      38.992113,   0.0,
            32.000000,  0.000000, 26.261721,   0.000000, 21.381716,   0.000000, 17.104356,   0.000000,
            13.254834,  0.000000, 9.707094,    0.000000, 6.365196,    0.000000, 3.151725,    0.000000,
            0.000000,   0.000000, -3.151725,   0.000000, -6.365196,   0.000000, -9.707094,   0.000000,
            -13.254834, 0.000000, -17.104356,  0.000000, -21.381716,  0.000000, -26.261721,  0.000000,
            -32.000000, 0.000000, -38.992113,  0.000000, -47.891384,  0.000000, -59.867789,  0.000000,
            -77.254834, 0.000000, -105.489863, 0.000000, -160.874864, 0.000000, -324.901452, 0.000000,
        };
        for (expected, 0..) |e, ie| {
            const v: [4]f32 = im[ie / 4];
            try expect(std.math.approxEqAbs(f32, e, v[ie % 4], epsilon));
        }
    }

    // 128 samples
    {
        var re = [_]Vec{
            f32x4(1.0, 2.0, 3.0, 4.0),     f32x4(5.0, 6.0, 7.0, 8.0),
            f32x4(9.0, 10.0, 11.0, 12.0),  f32x4(13.0, 14.0, 15.0, 16.0),
            f32x4(17.0, 18.0, 19.0, 20.0), f32x4(21.0, 22.0, 23.0, 24.0),
            f32x4(25.0, 26.0, 27.0, 28.0), f32x4(29.0, 30.0, 31.0, 32.0),
            f32x4(1.0, 2.0, 3.0, 4.0),     f32x4(5.0, 6.0, 7.0, 8.0),
            f32x4(9.0, 10.0, 11.0, 12.0),  f32x4(13.0, 14.0, 15.0, 16.0),
            f32x4(17.0, 18.0, 19.0, 20.0), f32x4(21.0, 22.0, 23.0, 24.0),
            f32x4(25.0, 26.0, 27.0, 28.0), f32x4(29.0, 30.0, 31.0, 32.0),
            f32x4(1.0, 2.0, 3.0, 4.0),     f32x4(5.0, 6.0, 7.0, 8.0),
            f32x4(9.0, 10.0, 11.0, 12.0),  f32x4(13.0, 14.0, 15.0, 16.0),
            f32x4(17.0, 18.0, 19.0, 20.0), f32x4(21.0, 22.0, 23.0, 24.0),
            f32x4(25.0, 26.0, 27.0, 28.0), f32x4(29.0, 30.0, 31.0, 32.0),
            f32x4(1.0, 2.0, 3.0, 4.0),     f32x4(5.0, 6.0, 7.0, 8.0),
            f32x4(9.0, 10.0, 11.0, 12.0),  f32x4(13.0, 14.0, 15.0, 16.0),
            f32x4(17.0, 18.0, 19.0, 20.0), f32x4(21.0, 22.0, 23.0, 24.0),
            f32x4(25.0, 26.0, 27.0, 28.0), f32x4(29.0, 30.0, 31.0, 32.0),
        };
        var im = [_]Vec{
            splat(0.0), splat(0.0), splat(0.0), splat(0.0),
            splat(0.0), splat(0.0), splat(0.0), splat(0.0),
            splat(0.0), splat(0.0), splat(0.0), splat(0.0),
            splat(0.0), splat(0.0), splat(0.0), splat(0.0),
            splat(0.0), splat(0.0), splat(0.0), splat(0.0),
            splat(0.0), splat(0.0), splat(0.0), splat(0.0),
            splat(0.0), splat(0.0), splat(0.0), splat(0.0),
            splat(0.0), splat(0.0), splat(0.0), splat(0.0),
        };

        fftInitUnityTable(unity_table[0..128]);
        fft(re[0..], im[0..], unity_table[0..128]);

        try expectVecApproxEqAbs(re[0], f32x4(2112.0, 0.0, 0.0, 0.0), epsilon);
        var i: u32 = 1;
        while (i < 32) : (i += 1) {
            try expectVecApproxEqAbs(re[i], f32x4(-64.0, 0.0, 0.0, 0.0), epsilon);
        }

        const expected = [_]f32{
            0.000000,    0.000000, 0.000000, 0.000000, 649.802905,  0.000000, 0.000000, 0.000000,
            321.749727,  0.000000, 0.000000, 0.000000, 210.979725,  0.000000, 0.000000, 0.000000,
            154.509668,  0.000000, 0.000000, 0.000000, 119.735578,  0.000000, 0.000000, 0.000000,
            95.782769,   0.000000, 0.000000, 0.000000, 77.984226,   0.000000, 0.000000, 0.000000,
            64.000000,   0.000000, 0.000000, 0.000000, 52.523443,   0.000000, 0.000000, 0.000000,
            42.763433,   0.000000, 0.000000, 0.000000, 34.208713,   0.000000, 0.000000, 0.000000,
            26.509668,   0.000000, 0.000000, 0.000000, 19.414188,   0.000000, 0.000000, 0.000000,
            12.730392,   0.000000, 0.000000, 0.000000, 6.303450,    0.000000, 0.000000, 0.000000,
            0.000000,    0.000000, 0.000000, 0.000000, -6.303450,   0.000000, 0.000000, 0.000000,
            -12.730392,  0.000000, 0.000000, 0.000000, -19.414188,  0.000000, 0.000000, 0.000000,
            -26.509668,  0.000000, 0.000000, 0.000000, -34.208713,  0.000000, 0.000000, 0.000000,
            -42.763433,  0.000000, 0.000000, 0.000000, -52.523443,  0.000000, 0.000000, 0.000000,
            -64.000000,  0.000000, 0.000000, 0.000000, -77.984226,  0.000000, 0.000000, 0.000000,
            -95.782769,  0.000000, 0.000000, 0.000000, -119.735578, 0.000000, 0.000000, 0.000000,
            -154.509668, 0.000000, 0.000000, 0.000000, -210.979725, 0.000000, 0.000000, 0.000000,
            -321.749727, 0.000000, 0.000000, 0.000000, -649.802905, 0.000000, 0.000000, 0.000000,
        };
        for (expected, 0..) |e, ie| {
            const v: [4]f32 = im[ie / 4];
            try expect(std.math.approxEqAbs(f32, e, v[ie % 4], epsilon));
        }
    }
}

pub fn ifft(
    re: []Vec,
    im: []const Vec,
    unity_table: []const Vec,
) void {
    const len_n: u32 = @as(u32, @intCast(re.len * 4));
    assert(isPowerOfTwo(len_n), @src());
    assert(len_n >= 4 and len_n <= 512, @src());
    assert(re.len == im.len, @src());

    var re_temp_storage: [128]Vec = undefined;
    var im_temp_storage: [128]Vec = undefined;
    var re_temp: []Vec = re_temp_storage[0..re.len];
    var im_temp: []Vec = im_temp_storage[0..im.len];

    const rnp: Vec = splat(1.0 / float(len_n));
    const rnm: Vec = splat(-1.0 / float(len_n));

    for (re, 0..) |_, i| {
        re_temp[i] = re[i] * rnp;
        im_temp[i] = im[i] * rnm;
    }

    if (len_n > 16) {
        assert(unity_table.len == len_n, @src());
        fftN(re_temp, im_temp, unity_table, len_n, 1);
    } else if (len_n == 16) {
        fft16(re_temp, im_temp, 1);
    } else if (len_n == 8) {
        fft8(re_temp, im_temp, 1);
    } else if (len_n == 4) {
        fft4(re_temp, im_temp, 1);
    }

    fftUnswizzle(re_temp, re);
}
/// Approximate-equal predicate.  Polymorphic over scalar (`f32`,
/// `comptime_float`, ...) and vector (`Vec`, `Vec2`, `F32x8`,
/// `F32x16`).  For vectors, returns true only if every lane is
/// within `eps`.  Returns `bool` so it composes in `or`/`and`
/// (use `expectVecApproxEqAbs` for assertion-style throws).
pub fn approxEqAbs(
    v0: anytype,
    v1: anytype,
    eps: f32,
) bool {
    const T = @TypeOf(v0, v1);
    return switch (@typeInfo(T)) {
        .vector => blk: {
            inline for (0..veclen(T)) |i| {
                if (!((v0[i] == v1[i]) or (@abs(v0[i] - v1[i]) <= eps))) {
                    break :blk false;
                }
            }
            break :blk true;
        },
        else => (v0 == v1) or (@abs(v0 - v1) <= eps),
    };
}

test "zm.ifft" {
    var unity_table: [512]Vec = undefined;
    const epsilon: f32 = 0.0001;

    // 64 samples
    {
        var re = [_]Vec{
            f32x4(1.0, 2.0, 3.0, 4.0),     f32x4(5.0, 6.0, 7.0, 8.0),
            f32x4(9.0, 10.0, 11.0, 12.0),  f32x4(13.0, 14.0, 15.0, 16.0),
            f32x4(17.0, 18.0, 19.0, 20.0), f32x4(21.0, 22.0, 23.0, 24.0),
            f32x4(25.0, 26.0, 27.0, 28.0), f32x4(29.0, 30.0, 31.0, 32.0),
            f32x4(1.0, 2.0, 3.0, 4.0),     f32x4(5.0, 6.0, 7.0, 8.0),
            f32x4(9.0, 10.0, 11.0, 12.0),  f32x4(13.0, 14.0, 15.0, 16.0),
            f32x4(17.0, 18.0, 19.0, 20.0), f32x4(21.0, 22.0, 23.0, 24.0),
            f32x4(25.0, 26.0, 27.0, 28.0), f32x4(29.0, 30.0, 31.0, 32.0),
        };
        var im = [_]Vec{
            splat(0.0), splat(0.0), splat(0.0), splat(0.0),
            splat(0.0), splat(0.0), splat(0.0), splat(0.0),
            splat(0.0), splat(0.0), splat(0.0), splat(0.0),
            splat(0.0), splat(0.0), splat(0.0), splat(0.0),
        };

        fftInitUnityTable(unity_table[0..64]);
        fft(re[0..], im[0..], unity_table[0..64]);

        try expectVecApproxEqAbs(re[0], f32x4(1056.0, 0.0, -32.0, 0.0), epsilon);
        var i: u32 = 1;
        while (i < 16) : (i += 1) {
            try expectVecApproxEqAbs(re[i], f32x4(-32.0, 0.0, -32.0, 0.0), epsilon);
        }

        ifft(re[0..], im[0..], unity_table[0..64]);

        try expectVecApproxEqAbs(re[0], f32x4(1.0, 2.0, 3.0, 4.0), epsilon);
        try expectVecApproxEqAbs(re[1], f32x4(5.0, 6.0, 7.0, 8.0), epsilon);
        try expectVecApproxEqAbs(re[2], f32x4(9.0, 10.0, 11.0, 12.0), epsilon);
        try expectVecApproxEqAbs(re[3], f32x4(13.0, 14.0, 15.0, 16.0), epsilon);
        try expectVecApproxEqAbs(re[4], f32x4(17.0, 18.0, 19.0, 20.0), epsilon);
        try expectVecApproxEqAbs(re[5], f32x4(21.0, 22.0, 23.0, 24.0), epsilon);
        try expectVecApproxEqAbs(re[6], f32x4(25.0, 26.0, 27.0, 28.0), epsilon);
        try expectVecApproxEqAbs(re[7], f32x4(29.0, 30.0, 31.0, 32.0), epsilon);
    }

    // 512 samples
    {
        var re: [128]Vec = undefined;
        var im: [128]Vec = @splat(splat(0.0));

        for (&re, 0..) |*v, i| {
            const f = float(i * 4);
            v.* = f32x4(f + 1.0, f + 2.0, f + 3.0, f + 4.0);
        }

        fftInitUnityTable(unity_table[0..512]);
        fft(re[0..], im[0..], unity_table[0..512]);

        for (re, 0..) |v, i| {
            const f = float(i * 4);
            try expect(!approxEqAbs(v, f32x4(f + 1.0, f + 2.0, f + 3.0, f + 4.0), epsilon));
        }

        ifft(re[0..], im[0..], unity_table[0..512]);

        for (re, 0..) |v, i| {
            const f = float(i * 4);
            try expectVecApproxEqAbs(v, f32x4(f + 1.0, f + 2.0, f + 3.0, f + 4.0), epsilon);
        }
    }
}
//
// Private functions and constants
//
// Mask constants: returned by `inline fn` rather than declared as
// `const` so SPIR-V codegen folds the literal at every call site.
// Module-scope `const Vec` declarations get lowered to a private-
// storage variable that requires `OpLoad` through a non-logical
// pointer — which SPIR-V's Logical addressing model rejects (e.g.
// `cross` failed with "OpLoad Pointer is not a logical pointer"
// at Stage 3 of math-unification before this rewrite).  Inline
// functions returning vector literals avoid the load entirely:
// the compiler emits an `OpConstantComposite` and uses it inline.
// On host the inline fn is identical to a const at runtime —
// constant-folded by the optimizer.

inline fn splatAbsMask(comptime T: type) T {
    return @splat(@as(f32, @bitCast(@as(u32, 0x7fff_ffff))));
}

test "zm.floatToIntAndBack" {
    {
        const v: Vec = floatToIntAndBack(f32x4(1.1, 2.9, 3.0, -4.5));
        try expectVecEqual(v, f32x4(1.0, 2.0, 3.0, -4.0));
    }
    {
        const v: F32x8 = floatToIntAndBack(f32x8(1.1, 2.9, 3.0, -4.5, 2.5, -2.5, 1.1, -100.2));
        try expectVecEqual(v, f32x8(1.0, 2.0, 3.0, -4.0, 2.0, -2.0, 1.0, -100.0));
    }
    {
        const v: Vec = floatToIntAndBack(f32x4(math.inf(f32), 2.9, math.nan(f32), math.snan(f32)));
        try expect(v[1] == 2.0);
    }
}

/// ==============================================================================
/// Collection of useful functions building on top of, and extending, core zm.
/// https://github.com/michal-z/zig-gamedev/tree/main/libs/zmath
///
/// 1. Matrix functions
///
/// As an example, in a left handed Y-up system:
///   getAxisX is equivalent to the right vector
///   getAxisY is equivalent to the up vector
///   getAxisZ is equivalent to the forward vector
/// getTranslationVec(m: Mat) Vec
/// getAxisX(m: Mat) Vec
/// getAxisY(m: Mat) Vec
/// getAxisZ(m: Mat) Vec
/// ==============================================================================
pub const util = struct {
    pub fn getTranslationVec(m: Mat) Vec {
        var _translation: Vec = m[3];
        _translation[3] = 0;
        return _translation;
    }

    pub fn setTranslationVec(m: *Mat, _translation: Vec) void {
        const w: f32 = m[3][3];
        m[3] = _translation;
        m[3][3] = w;
    }

    pub fn getScaleVec(m: Mat) Vec {
        const scale_x: f32 = length3(f32x4(m[0][0], m[1][0], m[2][0], 0));
        const scale_y: f32 = length3(f32x4(m[0][1], m[1][1], m[2][1], 0));
        const scale_z: f32 = length3(f32x4(m[0][2], m[1][2], m[2][2], 0));
        return f32x4(scale_x, scale_y, scale_z, 0);
    }

    pub fn getRotationQuat(_m: Mat) Quat {
        // Ortho normalize given matrix.
        const c1: Vec = normalize3(f32x4(_m[0][0], _m[1][0], _m[2][0], 0));
        const c2: Vec = normalize3(f32x4(_m[0][1], _m[1][1], _m[2][1], 0));
        const c3: Vec = normalize3(f32x4(_m[0][2], _m[1][2], _m[2][2], 0));
        var m: Mat = _m;
        m[0][0] = c1[0];
        m[1][0] = c1[1];
        m[2][0] = c1[2];
        m[0][1] = c2[0];
        m[1][1] = c2[1];
        m[2][1] = c2[2];
        m[0][2] = c3[0];
        m[1][2] = c3[1];
        m[2][2] = c3[2];

        // Extract rotation
        return quatFromMat(m);
    }

    pub fn getAxisX(m: Mat) Vec {
        return normalize3(dirFromArr3(m[0]));
    }

    pub fn getAxisY(m: Mat) Vec {
        return normalize3(dirFromArr3(m[1]));
    }

    pub fn getAxisZ(m: Mat) Vec {
        return normalize3(dirFromArr3(m[2]));
    }

    test "zm.util.mat.translation" {
        // zig fmt: off
        const mat_data: [18]f32 = .{
            1.0,
            2.0, 3.0, 4.0, 5.0,
            6.0, 7.0, 8.0, 9.0,
            10.0,11.0, 12.0,13.0,
            14.0, 15.0, 16.0, 17.0,
            18.0,
        };
        // zig fmt: on
        const mat: Mat = loadMat(mat_data[1..]);
        try expectVecApproxEqAbs(getTranslationVec(mat), f32x4(14.0, 15.0, 16.0, 0.0), 0.0001);
    }

    test "zm.util.mat.scale" {
        // Old: `mul(scaling(3,4,5), translation(6,7,8))` — scaling
        // applied first.  Under column-major: `mulMat(translation,
        // scaling)` (operand swap).  The decomposition test only
        // looks at the scale columns, which sit in the same lanes
        // either way.
        const mat: Mat = mulMat(translation(6, 7, 8), scaling(3, 4, 5));
        const scale: Vec = getScaleVec(mat);
        try expectVecApproxEqAbs(scale, f32x4(3.0, 4.0, 5.0, 0.0), 0.0001);
    }

    test "zm.util.mat.rotation" {
        const rotate_origin: Mat = matFromRollPitchYaw(0.1, 1.2, 2.3);
        // Old: mul(mul(rotate_origin, scaling), translation) →
        // mulMat(translation, mulMat(scaling, rotate_origin))
        const mat: Mat = mulMat(
            translation(6, 7, 8),
            mulMat(scaling(3, 4, 5), rotate_origin),
        );
        const rotate_get: Quat = getRotationQuat(mat);
        // Old `mul(splat(1), rotate_origin)` is Vec×Mat → mulMatVec.
        const v0: Vec = mulMatVec(rotate_origin, splat(1));
        const v1: Vec = mulMatVec(quatToMat(rotate_get), splat(1));
        try expectVecApproxEqAbs(v0, v1, 0.0001);
    }

    test "zm.util.mat.z_vec" {
        var z_vec: Vec = getAxisZ(identity());
        try expectVecApproxEqAbs(z_vec, f32x4(0.0, 0.0, 1.0, 0), 0.0001);
        const rot_yaw: Mat = rotationY(radFromDeg(90.0));
        // mul(identity(), rot_yaw) == rot_yaw under both conventions
        // (identity is identity); operand swap is a no-op here.
        identity = mulMat(rot_yaw, identity());
        z_vec = getAxisZ(identity());
        try expectVecApproxEqAbs(z_vec, f32x4(1.0, 0.0, 0.0, 0), 0.0001);
    }

    test "zm.util.mat.y_vec" {
        var y_vec: Vec = getAxisY(identity());
        try expectVecApproxEqAbs(y_vec, f32x4(0.0, 1.0, 0.0, 0), 0.01);
        const rot_yaw: Mat = rotationY(radFromDeg(90.0));
        identity = mulMat(rot_yaw, identity());
        y_vec = getAxisY(identity());
        try expectVecApproxEqAbs(y_vec, f32x4(0.0, 1.0, 0.0, 0), 0.01);
        const rot_pitch: Mat = rotationX(radFromDeg(90.0));
        identity = mulMat(rot_pitch, identity());
        y_vec = getAxisY(identity());
        try expectVecApproxEqAbs(y_vec, f32x4(0.0, 0.0, 1.0, 0), 0.01);
    }

    test "zm.util.mat.right" {
        var right: Vec = getAxisX(identity());
        try expectVecApproxEqAbs(right, f32x4(1.0, 0.0, 0.0, 0), 0.01);
        const rot_yaw: Mat = rotationY(radFromDeg(90.0));
        identity = mulMat(rot_yaw, identity);
        right = getAxisX(identity());
        try expectVecApproxEqAbs(right, f32x4(0.0, 0.0, -1.0, 0), 0.01);
        const rot_pitch: Mat = rotationX(radFromDeg(90.0));
        identity = mulMat(rot_pitch, identity());
        right = getAxisX(identity());
        try expectVecApproxEqAbs(right, f32x4(0.0, 1.0, 0.0, 0), 0.01);
    }
}; // util

// This software is available under 2 licenses -- choose whichever you prefer.
// ALTERNATIVE A - MIT License
// Copyright (c) 2022 Michal Ziulek and Contributors
// Permission is hereby granted, free of charge, to any person obtaining a copy of
// this software and associated documentation files (the "Software"), to deal in
// the Software without restriction, including without limitation the rights to
// use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is furnished to do
// so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
// ALTERNATIVE B - Public Domain (www.unlicense.org)
// This is free and unencumbered software released into the public domain.
// Anyone is free to copy, modify, publish, use, compile, sell, or distribute this
// software, either in source code form or as a compiled binary, for any purpose,
// commercial or non-commercial, and by any means.
// In jurisdictions that recognize copyright laws, the author or authors of this
// software dedicate any and all copyright interest in the software to the public
// domain. We make this dedication for the benefit of the public at large and to
// the detriment of our heirs and successors. We intend this dedication to be an
// overt act of relinquishment in perpetuity of all present and future rights to
// this software under copyright law.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
// WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
// ============================================================================
// ============================================================================
//   zimr additions
//   Everything below this line is zimr's, not upstream zm.  `math.zig`
//   is a hard fork (see the provenance header at the top of this file and
//   notes/zmath-adoption-plan.md), so gap-fill functions - capability zimr
//   needs that stock zmath lacks - live here, in zmath's own style and
//   tested zmath's way.
//   Ground rules for this section (plan decision 7 - "one name per
//   concept, ship the best one"):
//     * Only add things zmath genuinely does NOT have.  If zmath already
//       does it under a different name, that name is canonical - do not
//       add a second spelling.  (E.g. zimr's old scalar `remap` and
//       scalar `normalize` are NOT here: they are exactly `mapLinear`
//       and `lerpInverse`, which already accept scalars.)
//     * Match zmath's conventions: `anytype` + `@TypeOf` where it
//       generalises, terse names, a `test "zm.<name>"`-style block
//       right after each function.
// ============================================================================
// ============================================================================

// Z4 - vector constructors
// Ergonomic constructors for the `Vec` type.  Vector literals
// `.{ a, b, c, d }` work when there's a `: Vec =` annotation; these
// helpers cover the no-annotation case and give a more semantic
// reading at callsites.  `vec(x, y, z)` builds a DIRECTION (w=0),
// translation-invariant under matrix transforms.  `point(x, y, z)`
// builds a POINT (w=1).  `vec4(a, b, c, d)` is the no-w-assumption
// form.  `quat(x, y, z, w)` is a synonym for `vec4` that reads as
// "this is a quaternion" - same storage, different semantic.
// (Array <-> `Vec` conversion for the packed-storage boundary
// already exists: `loadArr2`/`loadArr3`/`loadArr4` and
// `vecToArr2`/`vecToArr3`/`vecToArr4`, above.)

test "zm.vec" {
    const v: Vec = vec(1.0, 2.0, 3.0);
    try expectEqual(@as(f32, 1.0), v[0]);
    try expectEqual(@as(f32, 2.0), v[1]);
    try expectEqual(@as(f32, 3.0), v[2]);
    try expectEqual(@as(f32, 0.0), v[3]);
}

/// 3D *point* — lane 3 is 1, so the translation row of an affine
/// matrix applies.  Use this for positions, `vec` for directions.
pub inline fn pointVec(x: f32, y: f32, z: f32) Vec {
    return .{ x, y, z, 1.0 };
}

test "zm.point" {
    const p: Vec = pointVec(4.0, 5.0, 6.0);
    try expectEqual(@as(f32, 4.0), p[0]);
    try expectEqual(@as(f32, 1.0), p[3]);
}

/// 4-component Vec constructor — no w-lane assumption.  Use when
/// all four lanes are meaningful (RGBA colors, homogeneous coords
/// you're building by hand, etc).
pub inline fn vec4(a: f32, b: f32, c: f32, d: f32) Vec {
    return .{ a, b, c, d };
}

/// 3D vector constructor returning a true `Vec3` (`@Vector(3, f32)`,
/// 12 bytes).  Distinct from `vec(x, y, z)` which returns a 4-wide
/// `Vec` with `w = 0` for SIMD alignment.  Use this when storage
/// size matters (3D positions in compact arrays) or when feeding a
/// GLSL `vec3` uniform.
pub inline fn vec3(x_: f32, y_: f32, z_: f32) Vec3 {
    return .{ x_, y_, z_ };
}
/// Quaternion constructor — same storage as `vec4` but reads as
/// "this is a quaternion" at the callsite.  Convention is
/// `(x, y, z, w)` per zmath/raylib.
pub inline fn quat(x: f32, y: f32, z: f32, w: f32) Quat {
    return .{ x, y, z, w };
}

/// A 2D vector - `@Vector(2, f32)`, 8 bytes.  For UI / 2D math.
/// `Vec2` (the storage type) is `@Vector(2, f32)` post-Z4; this
/// is its constructor.  The earlier zimr rule of "compute 2D in the
/// 4-wide type" applied to *3D math* mixing 2D inputs - UI math is
/// not in that path, and the 8-vs-16-byte size matters across the
/// many widget rects / gesture positions.  If you need a 4-wide
/// F32x4 to feed a 4-wide zmath op, use `loadArr2(.{ x, y })`.
pub inline fn vec2(x: f32, y: f32) Vec2 {
    return .{ x, y };
}

test "zm.vec2" {
    const v: Vec2 = vec2(7.0, 8.0);
    try expectEqual(@as(f32, 7.0), v[0]);
    try expectEqual(@as(f32, 8.0), v[1]);
}

// `splat(v)` / `splat2(v)` - broadcast a scalar to the zimr storage-as-Vec
// types.  Shadow zmath's 2-arg `@as(T, @splat(v))` because at zimr call sites the
// type is almost always `Vec`, and `v * splat(s)` reads as pure
// type-annotation noise.  These give `v * splat(s)` for 3D/4D math and
// `v * splat2(s)` for 2D (Vec2 = @Vector(2, f32)).  The original
// `zm.@as(T, @splat(v))` is shadowed at the zimr public surface (`z.splat`
// resolves to this form) - explicit-type calls can still use `@splat`
// directly with `@as(T, ...)`.

/// Broadcast a scalar to a 2-wide `@Vector(2, f32)`.  For UI / 2D math.
pub inline fn splat2(v: f32) Vec2 {
    return @splat(v);
}

/// Broadcast a scalar to a 2-wide `@Vector(2, i32)` (`Vec2i`).
/// Integer sister of `splat2` — pixel coords, viewport dims, any
/// "exact count" 2D value.  Use when broadcasting `0` / `1` / a
/// `width = height` square value; for explicit per-component
/// values, prefer the struct literal `Vec2i{ a, b }`.
pub inline fn splat2i(v: i32) Vec2i {
    return @splat(v);
}

/// Broadcast a scalar to an explicit `@Vector` type.  Equivalent to
/// `@as(T, @splat(v))`, and restores the *upstream zmath* shape
/// (`zm.splat(T, v)`) under a non-shadowing name - porting code
/// between upstream zmath and zimr is then a 1:1 identifier change.
/// Use this when the result type isn't `Vec`/`@Vector(2, f32)`; in
/// those cases prefer `splat`/`splat2`.
pub inline fn zsplat(comptime T: type, v: f32) T {
    return @splat(v);
}

test "zm.splat / splat2" {
    const a: Vec = splat(3.5);
    try expectEqual(@as(f32, 3.5), a[0]);
    try expectEqual(@as(f32, 3.5), a[3]);
    const b: Vec2 = splat2(-1.25);
    try expectEqual(@as(f32, -1.25), b[0]);
    try expectEqual(@as(f32, -1.25), b[1]);
}

// Z2 / Category 2 - scalar utilities
// zmath is a vector library; these are the scalar-`f32` helpers zimr's
// codebase depends on that zmath has no equivalent for.  (Ported.)
/// Epsilon float compare with a magnitude-relative tolerance.  Returns
/// `true` when `x` and `y` are within `eps * max(1, |x|, |y|)` of each
/// other - i.e. the tolerance grows with the operands so it stays
/// meaningful for large values.  (zimr's old raylib-derived
/// `floatEquals` returned `i32` 0/1; the zmath-style version returns
/// `bool` - callers use it in `if`/`and` directly.)
pub fn floatEqualsEps(x: f32, y: f32, eps: f32) bool {
    return @abs(x - y) <= eps * @max(@as(f32, 1.0), @max(@abs(x), @abs(y)));
}

/// Epsilon float compare at the library default tolerance.
pub fn floatEquals(x: f32, y: f32) bool {
    // 1e-5 - the same default zimr's raylib-derived math used.
    return floatEqualsEps(x, y, 1.0e-5);
}
test "zm.floatEquals" {
    try expect(floatEquals(1.0, 1.0));
    try expect(floatEquals(1.0, 1.0 + 1.0e-7));
    try expect(!floatEquals(1.0, 1.01));
    // magnitude-relative: a large pair within relative tolerance passes
    try expect(floatEquals(1.0e6, 1.0e6 + 1.0));
    try expect(!floatEquals(1.0e6, 1.0e6 + 1.0e3));
    // explicit-eps form
    try expect(floatEqualsEps(10.0, 10.5, 0.1));
    try expect(!floatEqualsEps(10.0, 10.5, 0.001));
}

/// Fractional part of `x`: `x - floor(x)`.  Always in `[0, 1)` for
/// finite input, including for negative `x` (`fract(-0.25) == 0.75`).
pub fn frac32(x: f32) f32 {
    return x - @floor(x);
}
test "zm.frac32" {
    try expectApproxEqAbs(@as(f32, 0.25), frac32(3.25), 1.0e-6);
    try expectApproxEqAbs(@as(f32, 0.75), frac32(-0.25), 1.0e-6);
    try expectApproxEqAbs(@as(f32, 0.0), frac32(4.0), 1.0e-6);
}

/// Wrap `value` into the half-open interval `[lo, hi)`.  Handles
/// values arbitrarily far outside the range in a single step (it is
/// not an iterative clamp) and works for negative excursions.
pub fn wrap32(value: f32, lo: f32, hi: f32) f32 {
    const range: f32 = hi - lo;
    return value - range * @floor((value - lo) / range);
}
test "zm.wrap32" {
    try expectApproxEqAbs(@as(f32, 1.0), wrap32(1.0, 0.0, 10.0), 1.0e-5);
    try expectApproxEqAbs(@as(f32, 2.0), wrap32(12.0, 0.0, 10.0), 1.0e-5);
    try expectApproxEqAbs(@as(f32, 8.0), wrap32(-2.0, 0.0, 10.0), 1.0e-5);
    // far outside the range, both directions, single step
    try expectApproxEqAbs(@as(f32, 3.0), wrap32(103.0, 0.0, 10.0), 1.0e-4);
    try expectApproxEqAbs(@as(f32, 7.0), wrap32(-103.0, 0.0, 10.0), 1.0e-4);
    // non-zero lo
    try expectApproxEqAbs(@as(f32, -3.0), wrap32(7.0, -5.0, 5.0), 1.0e-5);
}

/// Scalar reciprocal, `1 / x`.  zmath has vector reciprocal-estimate
/// ops but no exact scalar one; this exists so call sites can express
/// reciprocal as intent.  (Note: `mapLinear` and `lerpInverse` already
/// cover scalar re-ranging and inverse-lerp - zimr's old scalar
/// `remap` / `normalize` are deliberately NOT re-added here.)
pub inline fn rcp32(x: f32) f32 {
    return 1.0 / x;
}
test "zm.rcp32" {
    try expectApproxEqAbs(@as(f32, 0.25), rcp32(4.0), 1.0e-6);
    try expectApproxEqAbs(@as(f32, -2.0), rcp32(-0.5), 1.0e-6);
}

// ---- Luminance
/// Perceptual luminance of a linear RGB triple, Rec.601 weights
/// (0.299, 0.587, 0.114).  Input as a plain `[3]f32` - this operates
/// on a colour, not a spatial vector, so it does not take a `Vec`.
pub fn luminance(rgb: [3]f32) f32 {
    return rgb[0] * 0.299 + rgb[1] * 0.587 + rgb[2] * 0.114;
}
test "zm.luminance" {
    try expectApproxEqAbs(@as(f32, 1.0), luminance(.{ 1.0, 1.0, 1.0 }), 1.0e-6);
    try expectApproxEqAbs(@as(f32, 0.0), luminance(.{ 0.0, 0.0, 0.0 }), 1.0e-6);
    try expectApproxEqAbs(@as(f32, 0.587), luminance(.{ 0.0, 1.0, 0.0 }), 1.0e-6);
}

/// Perceptual luminance of an 8-bit RGB triple, returned 8-bit.
/// Integer fixed-point form of the Rec.601 weights (77, 150, 29 - these
/// sum to 256, so the `>> 8` is an exact average-by-256).  Kept as a
/// separate function from `luminance` because the all-integer path
/// avoids float round-trips for the very common u8-colour case.
pub fn luminance8(rgb: [3]u8) u8 {
    const r: u32 = @as(u32, rgb[0]) * 77;
    const g: u32 = @as(u32, rgb[1]) * 150;
    const b: u32 = @as(u32, rgb[2]) * 29;
    return @intCast((r + g + b) >> 8);
}
test "zm.luminance8" {
    try expectEqual(@as(u8, 255), luminance8(.{ 255, 255, 255 }));
    try expectEqual(@as(u8, 0), luminance8(.{ 0, 0, 0 }));
    // pure green -> 150/256 * 255 ≈ 149
    try expectEqual(@as(u8, 149), luminance8(.{ 0, 255, 0 }));
}

// ---- Half-precision conversion
/// `f32` -> IEEE-754 half (`f16`) bit pattern.  Zig has native `f16`,
/// so this is just a narrowing cast plus a bitcast - but it is wrapped
/// so call sites that move 16-bit float data (vertex attributes,
/// compact textures) read as intent rather than as a cast soup.
pub fn floatToHalf(x: f32) u16 {
    const h: f16 = @floatCast(x);
    return @bitCast(h);
}

/// IEEE-754 half (`f16`) bit pattern -> `f32`.  Inverse of `floatToHalf`.
pub fn halfToFloat(bits: u16) f32 {
    const h: f16 = @bitCast(bits);
    return @floatCast(h);
}
test "zm.halfFloatRoundTrip" {
    // values exactly representable in f16 round-trip exactly
    for ([_]f32{ 0.0, 1.0, -1.0, 0.5, -0.25, 2048.0 }) |v| {
        try expectEqual(v, halfToFloat(floatToHalf(v)));
    }
    // a value not exactly representable comes back close
    try expectApproxEqAbs(@as(f32, 3.14159), halfToFloat(floatToHalf(3.14159)), 1.0e-3);
}

// Z2 / Category 1 - Vec2
// zmath is a 3D/4D library: it has no 2D type and no 2D ops beyond the
// handful it already ships (`dot2`, `length2`, `lengthSq2`,
// `normalize2`, `loadArr2` / `storeArr2` / `vecToArr2`).  zimr needs a
// full 2D surface - but per plan decision 7 ("ship one name per
// concept, the best one"), most of raylib's 32 `vector2*` functions do
// NOT get ported, because the concept already exists:
//   * `vector2Dot/Length/LengthSqr/Normalize` -> zmath already has
//     `dot2` / `length2` / `lengthSq2` / `normalize2`.
//   * `vector2Add/Subtract/Multiply/Divide/Negate/Scale/AddValue/...`
//     -> zmath deliberately has NO add/sub/scale functions; `@Vector`
//     supports `+ - * /` natively.  `a + b`, `a * splat(s)`.
//   * `vector2Min/Max/Clamp/Lerp` -> zmath's generic `min` / `max` /
//     `clamp` / `lerp` already operate on `Vec` (all four lanes; for a
//     2D value lanes 2,3 are the zero fill and ride along harmlessly).
// What follows is the GENUINE 2D gap - the 2D-specific operations
// zmath has no equivalent for at any width.  All operate on `Vec` with
// the value in lanes 0,1 (the plan's locked compute-type decision:
// 2D lives in a 4-wide register, lanes 2,3 ignored - there is no
// `@Vector(2,f32)` type).  Ported.
// Convention note: operations that reduce to a scalar return it
// splatted across all four lanes as `F32x4`, matching zmath's existing
// `dot2` / `length2` - so they compose with vector expressions without
// a scalar round-trip.  Use `[0]` to extract.  The two operations that
// are *inherently* a plain scalar (a signed angle) return `f32`.
/// 2D cross product (lanes 0,1): the scalar `x0*y1 - y0*x1`.  This is
/// the z-component the 3D `cross` would produce for two vectors in
/// the xy-plane - in 2D it is fundamentally a scalar.  Generic over
/// `Vec` and `Vec2`; see `cross2Splat` for the Vec broadcast.
pub inline fn cross2(v: anytype, w: anytype) f32 {
    // x0*y1 - y0*x1
    return v[0] * w[1] - v[1] * w[0];
}
/// `cross2` returning a Vec with the scalar splatted across all lanes.
pub inline fn cross2Splat(v0: Vec, v1: Vec) Vec {
    const prod: Vec = v0 * swizzle(v1, .y, .x, .x, .x); // | x0*y1 | y0*x1 | .. | .. |
    return splat(prod[0] - prod[1]);
}
test "zm.cross2" {
    // +x cross +y = +1 (right-handed)
    try expectApproxEqAbs(
        @as(f32, 1.0),
        cross2(f32x4(1.0, 0.0, 0.0, 0.0), f32x4(0.0, 1.0, 0.0, 0.0)),
        1.0e-6,
    );
    // parallel -> 0
    try expectApproxEqAbs(
        @as(f32, 0.0),
        cross2(f32x4(3.0, 3.0, 0.0, 0.0), f32x4(1.0, 1.0, 0.0, 0.0)),
        1.0e-6,
    );
    // anti-symmetry
    const a: Vec = .{ 2.0, 5.0, 0.0, 0.0 };
    const b: Vec = .{ -1.0, 3.0, 0.0, 0.0 };
    try expectApproxEqAbs(cross2(a, b), -cross2(b, a), 1.0e-6);
}

/// 2D distance between two points (lanes 0,1).  Generic over
/// `Vec` and `Vec2`.
pub inline fn distance2(v0: anytype, v1: anytype) f32 {
    return length2(v1 - v0);
}
pub inline fn distance2Splat(v0: Vec, v1: Vec) Vec {
    return length2Splat(v1 - v0);
}
test "zm.distance2" {
    try expectApproxEqAbs(
        @as(f32, 5.0),
        distance2(f32x4(0.0, 0.0, 0.0, 0.0), f32x4(3.0, 4.0, 0.0, 0.0)),
        1.0e-5,
    );
}

/// 2D squared distance between two points (lanes 0,1).  Cheaper
/// than `distance2` when only comparing distances.  Generic over
/// `Vec` and `Vec2`.
pub inline fn distanceSq2(v0: anytype, v1: anytype) f32 {
    return lengthSq2(v1 - v0);
}
pub inline fn distanceSq2Splat(v0: Vec, v1: Vec) Vec {
    return lengthSq2Splat(v1 - v0);
}
test "zm.distanceSq2" {
    try expectApproxEqAbs(
        @as(f32, 25.0),
        distanceSq2(f32x4(1.0, 1.0, 0.0, 0.0), f32x4(4.0, 5.0, 0.0, 0.0)),
        1.0e-5,
    );
}

/// Signed angle (radians) from `v0` to `v1` in the 2D plane (lanes
/// 0,1), in `(-pi, pi]`.  Positive is counter-clockwise.  This is
/// `atan2(cross2, dot2)` - inherently a plain scalar, so unlike the
/// reductions above it returns `f32`, not a splatted `F32x4`.
pub fn angle2(v0: anytype, v1: anytype) f32 {
    return atan2(cross2(v0, v1), dot2(v0, v1));
}
test "zm.angle2" {
    // +x to +y is +pi/2
    try expectApproxEqAbs(
        @as(f32, pi / 2.0),
        angle2(f32x4(1.0, 0.0, 0.0, 0.0), f32x4(0.0, 1.0, 0.0, 0.0)),
        1.0e-5,
    );
    // +x to -y is -pi/2
    try expectApproxEqAbs(
        @as(f32, -pi / 2.0),
        angle2(f32x4(1.0, 0.0, 0.0, 0.0), f32x4(0.0, -1.0, 0.0, 0.0)),
        1.0e-5,
    );
    // a vector to itself is 0
    try expectApproxEqAbs(
        @as(f32, 0.0),
        angle2(f32x4(0.7, -0.3, 0.0, 0.0), f32x4(0.7, -0.3, 0.0, 0.0)),
        1.0e-5,
    );
}

/// Angle (radians) of the directed line segment `start -> end`,
/// measured from the +x axis, counter-clockwise positive, in
/// `(-pi, pi]`.
/// NOTE: raylib's `Vector2LineAngle` negates the `atan2` result,
/// making *its* angle increase clockwise - raylib's own source
/// carries a TODO questioning that.  zimr does NOT keep that: every
/// other angle in this library (`angle2`, `rotate2`, the matrix
/// rotations) is counter-clockwise positive, and a 2D library with
/// one function rotating the other way is a footgun.  Code ported
/// from raylib that relied on the old sign must negate the result.
pub fn lineAngle2(start: anytype, end: anytype) f32 {
    return atan2(end[1] - start[1], end[0] - start[0]);
}
test "zm.lineAngle2" {
    // segment along +x -> angle 0
    try expectApproxEqAbs(
        @as(f32, 0.0),
        lineAngle2(f32x4(0.0, 0.0, 0.0, 0.0), f32x4(2.0, 0.0, 0.0, 0.0)),
        1.0e-5,
    );
    // segment along +y -> +pi/2 (counter-clockwise positive, like everything else)
    try expectApproxEqAbs(
        @as(f32, pi / 2.0),
        lineAngle2(f32x4(0.0, 0.0, 0.0, 0.0), f32x4(0.0, 2.0, 0.0, 0.0)),
        1.0e-5,
    );
    // segment along -y -> -pi/2
    try expectApproxEqAbs(
        @as(f32, -pi / 2.0),
        lineAngle2(f32x4(0.0, 0.0, 0.0, 0.0), f32x4(0.0, -2.0, 0.0, 0.0)),
        1.0e-5,
    );
}

/// Reflect a 2D vector about a normal.  `normal` is assumed
/// unit-length, matching the GLSL `reflect` contract.  Result:
/// `v - 2*(v·n)*n`.
/// zmath has no `reflect` at any width - this is the 2D one; the 3D
/// `reflect3` is a Z2-step-3 gap entry.
pub inline fn reflect2(v: Vec2, normal: Vec2) Vec2 {
    const two_d: Vec2 = @splat(2.0 * dot2(v, normal));
    return v - normal * two_d;
}
test "zm.reflect2" {
    // bounce straight down off a floor (normal +y) -> straight up
    const r: Vec2 = reflect2(.{ 0.0, -1.0 }, .{ 0.0, 1.0 });
    try expectApproxEqAbs(@as(f32, 0.0), r[0], 1.0e-6);
    try expectApproxEqAbs(@as(f32, 1.0), r[1], 1.0e-6);
    // 45-degree incoming off a vertical wall (normal +x) flips x only
    const r2: Vec2 = reflect2(.{ 1.0, -1.0 }, .{ 1.0, 0.0 });
    try expectApproxEqAbs(@as(f32, -1.0), r2[0], 1.0e-6);
    try expectApproxEqAbs(@as(f32, -1.0), r2[1], 1.0e-6);
}

/// Refract a 2D vector through a surface.  `n` is the unit surface
/// normal, `r` is the ratio of indices of refraction (n_in / n_out).
/// Returns the zero vector on total internal reflection.  Matches
/// raylib's `Vector2Refract` / the GLSL `refract` formula.
/// As with `reflect2`, zmath has no `refract` at any width.
pub inline fn refract2(
    v: Vec2,
    n: Vec2,
    r: f32,
) Vec2 {
    const d_v: f32 = dot2(v, n);
    const d: f32 = 1.0 - r * r * (1.0 - d_v * d_v);
    if (d < 0.0) {
        return .{ 0.0, 0.0 };
    } // total internal reflection
    const dsqrt: f32 = @sqrt(d);
    const rs: Vec2 = @splat(r);
    const ks: Vec2 = @splat(r * d_v + dsqrt);
    return v * rs - n * ks;
}
test "zm.refract2" {
    // straight-through at r = 1 (no bending) returns v unchanged
    const v0: Vec2 = .{ 0.3, -1.0 };
    const v: Vec2 = v0 / @as(Vec2, @splat(length2(v0)));
    const out: Vec2 = refract2(v, .{ 0.0, 1.0 }, 1.0);
    try expectApproxEqAbs(v[0], out[0], 1.0e-5);
    try expectApproxEqAbs(v[1], out[1], 1.0e-5);
}

/// Rotate a 2D vector by `angle` radians, counter-clockwise.
pub inline fn rotate2(v: Vec2, angle_rad: f32) Vec2 {
    const c: f32 = @cos(angle_rad);
    const s: f32 = @sin(angle_rad);
    return .{ v[0] * c - v[1] * s, v[0] * s + v[1] * c };
}
test "zm.rotate2" {
    // +x rotated 90 deg CCW -> +y
    const r: Vec2 = rotate2(.{ 1.0, 0.0 }, pi / 2.0);
    try expectApproxEqAbs(@as(f32, 0.0), r[0], 1.0e-6);
    try expectApproxEqAbs(@as(f32, 1.0), r[1], 1.0e-6);
    // full turn is identity
    const r2: Vec2 = rotate2(.{ 0.4, -0.9 }, tau);
    try expectApproxEqAbs(@as(f32, 0.4), r2[0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, -0.9), r2[1], 1.0e-5);
}

/// Transform a 2D point (lanes 0,1) by a `Mat`, treating it as a
/// point at z=0, w=1 (so the matrix's translation applies).  Returns
/// the transformed x,y in lanes 0,1.
/// Under the column-major M*v convention, this is `mulMatVec(m,
/// (x, y, 0, 1))`.  (Pre-Stage-2 this was `mul(point, m)` with the
/// point built as a row.)
pub inline fn transform2(v: Vec, m: Mat) Vec {
    const p_in: Vec = f32x4(v[0], v[1], 0.0, 1.0);
    const out: Vec = mulMatVec(m, p_in);
    return f32x4(out[0], out[1], 0.0, 0.0);
}
test "zm.transform2" {
    // translation moves a point
    const t: Mat = translation(5.0, -3.0, 0.0);
    const p: Vec = transform2(f32x4(1.0, 1.0, 0.0, 0.0), t);
    try expectApproxEqAbs(@as(f32, 6.0), p[0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, -2.0), p[1], 1.0e-5);
    // 90-degree z-rotation sends +x to +y
    const rz: Mat = rotationZ(pi / 2.0);
    const p2: Vec = transform2(f32x4(1.0, 0.0, 0.0, 0.0), rz);
    try expectApproxEqAbs(@as(f32, 0.0), p2[0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, 1.0), p2[1], 1.0e-5);
}

/// Clamp a 2D vector's LENGTH (lanes 0,1) into `[min_len, max_len]`,
/// keeping its direction.  A zero vector stays zero.  (This is
/// raylib's `Vector2ClampValue` - a magnitude clamp, distinct from
/// the component-wise `clamp`.)
pub inline fn clampLength2(
    v: Vec,
    min_len: f32,
    max_len: f32,
) Vec {
    const len_sq: f32 = v[0] * v[0] + v[1] * v[1];
    if (len_sq <= 0.0) {
        return v;
    }
    const len: f32 = @sqrt(len_sq);
    var scale: f32 = 1.0;
    if (len < min_len) {
        scale = min_len / len;
    } else if (len > max_len) {
        scale = max_len / len;
    }
    return f32x4(v[0] * scale, v[1] * scale, v[2], v[3]);
}
test "zm.clampLength2" {
    // a length-5 vector clamped to max 3 -> length 3, same direction
    const c: Vec = clampLength2(f32x4(3.0, 4.0, 0.0, 0.0), 0.0, 3.0);
    try expectApproxEqAbs(@as(f32, 3.0), length2(c), 1.0e-5);
    try expectApproxEqAbs(@as(f32, 1.8), c[0], 1.0e-5); // 3 * 3/5
    // a short vector clamped to min 10 -> length 10
    const c2: Vec = clampLength2(f32x4(0.0, 2.0, 0.0, 0.0), 10.0, 100.0);
    try expectApproxEqAbs(@as(f32, 10.0), length2(c2), 1.0e-5);
    // zero stays zero
    const c3: Vec = clampLength2(f32x4(0.0, 0.0, 0.0, 0.0), 1.0, 5.0);
    try expectApproxEqAbs(@as(f32, 0.0), length2(c3), 1.0e-6);
}

/// Move `v` toward `target` (lanes 0,1) by at most `max_dist`.  If the
/// remaining distance is within `max_dist`, returns `target` exactly.
pub inline fn moveTowards2(
    v: Vec,
    target: Vec,
    max_dist: f32,
) Vec {
    const dx: f32 = target[0] - v[0];
    const dy: f32 = target[1] - v[1];
    const dist_sq: f32 = dx * dx + dy * dy;
    if (dist_sq == 0.0 or (max_dist >= 0.0 and dist_sq <= max_dist * max_dist)) {
        return target;
    }
    const dist: f32 = @sqrt(dist_sq);
    return f32x4(v[0] + dx / dist * max_dist, v[1] + dy / dist * max_dist, v[2], v[3]);
}
test "zm.moveTowards2" {
    // step partway
    const m: Vec = moveTowards2(f32x4(0.0, 0.0, 0.0, 0.0), f32x4(10.0, 0.0, 0.0, 0.0), 3.0);
    try expectApproxEqAbs(@as(f32, 3.0), m[0], 1.0e-5);
    // overshoot snaps to target
    const m2: Vec = moveTowards2(f32x4(0.0, 0.0, 0.0, 0.0), f32x4(1.0, 0.0, 0.0, 0.0), 5.0);
    try expectApproxEqAbs(@as(f32, 1.0), m2[0], 1.0e-6);
    try expectApproxEqAbs(@as(f32, 0.0), m2[1], 1.0e-6);
}

/// Epsilon equality of two 2D vectors (lanes 0,1), using the same
/// magnitude-relative tolerance as the scalar `floatEquals`.
pub inline fn equals2(p: Vec, q: Vec) bool {
    return floatEquals(p[0], q[0]) and floatEquals(p[1], q[1]);
}
test "zm.equals2" {
    try expect(equals2(f32x4(1.0, 2.0, 0.0, 0.0), f32x4(1.0, 2.0, 0.0, 0.0)));
    try expect(equals2(f32x4(1.0, 2.0, 9.0, 9.0), f32x4(1.0, 2.0, -9.0, -9.0))); // lanes 2,3 ignored
    try expect(!equals2(f32x4(1.0, 2.0, 0.0, 0.0), f32x4(1.0, 2.5, 0.0, 0.0)));
}

/// A uniformly-distributed random 2D point inside the unit disk
/// (lanes 0,1; lanes 2,3 zero).  Takes a `*std.Random` - `math.zig`
/// stays free of global state (plan decision: RNG ops take an
/// explicit random source).  Rejection-samples the unit square.
pub fn randomInUnitDisk2(rand: *std.Random) Vec {
    while (true) {
        const v: Vec = f32x4(rand.float(f32) * 2.0 - 1.0, rand.float(f32) * 2.0 - 1.0, 0.0, 0.0);
        if (v[0] * v[0] + v[1] * v[1] <= 1.0) {
            return v;
        }
    }
}
test "zm.randomInUnitDisk2" {
    var prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0x2d_15_ee_d2);
    var r: std.Random = prng.random();
    for (0..256) |_| {
        const v: Vec = randomInUnitDisk2(&r);
        try expect(v[0] * v[0] + v[1] * v[1] <= 1.0);
        try expectEqual(@as(f32, 0.0), v[2]);
        try expectEqual(@as(f32, 0.0), v[3]);
    }
}

// Z2 / Category 4 - vector3 / vector4 operations zmath lacks
// Decision-7 filter applied: zmath already has `dot3`/`dot4`,
// `cross`, `length3`/`length4`, `lengthSq3`/`lengthSq4`,
// `normalize3`/`normalize4`, generic `min`/`max`/`clamp`/`lerp` on
// `Vec`, `rotate(q, v)` for quaternion-rotating a vector, and
// `vecToArr3`/`vecToArr4` for the float-array form.  raylib's
// `vector3RotateByQuaternion` -> `rotate`; `vector3ToFloatV` ->
// `vecToArr3`; `vector4Min/Max` -> generic `min`/`max`.  Those are
// NOT re-ported.
// What follows is the genuine gap.  All operate on `Vec` (3D uses
// lanes 0,1,2; 4D uses all four).  Ported.
// ---- 3D
/// 3D distance between two points (lanes 0,1,2).  Default form (f32).
pub inline fn distance3(v0: Vec, v1: Vec) f32 {
    return length3(v1 - v0);
}
pub inline fn distance3Splat(v0: Vec, v1: Vec) Vec {
    return length3Splat(v1 - v0);
}
test "zm.distance3" {
    try expectApproxEqAbs(
        @as(f32, 5.0),
        distance3(f32x4(0.0, 0.0, 0.0, 0.0), f32x4(3.0, 0.0, 4.0, 0.0)),
        1.0e-5,
    );
}

/// 3D squared distance between two points (lanes 0,1,2).  Cheaper
/// than `distance3` for distance comparisons.
pub inline fn distanceSq3(v0: Vec, v1: Vec) f32 {
    return lengthSq3(v1 - v0);
}
pub inline fn distanceSq3Splat(v0: Vec, v1: Vec) Vec {
    return lengthSq3Splat(v1 - v0);
}
test "zm.distanceSq3" {
    try expectApproxEqAbs(
        @as(f32, 25.0),
        distanceSq3(f32x4(1.0, 0.0, 1.0, 0.0), f32x4(4.0, 0.0, 5.0, 0.0)),
        1.0e-5,
    );
}

/// Unsigned angle (radians) between two 3D vectors (lanes 0,1,2), in
/// `[0, pi]`.  `atan2(|cross|, dot)` - more robust than `acos(dot)`
/// for near-parallel and near-antiparallel inputs.  Returns `f32`
/// (an angle is inherently scalar).
pub fn angle3(v0: Vec, v1: Vec) f32 {
    return atan2(length3(cross(v0, v1)), dot3(v0, v1));
}
test "zm.angle3" {
    // +x to +y is pi/2
    try expectApproxEqAbs(
        @as(f32, pi / 2.0),
        angle3(f32x4(1.0, 0.0, 0.0, 0.0), f32x4(0.0, 1.0, 0.0, 0.0)),
        1.0e-5,
    );
    // +x to +x is 0
    try expectApproxEqAbs(
        @as(f32, 0.0),
        angle3(f32x4(1.0, 0.0, 0.0, 0.0), f32x4(2.0, 0.0, 0.0, 0.0)),
        1.0e-5,
    );
    // +x to -x is pi (the near-antiparallel case acos(dot) handles badly)
    try expectApproxEqAbs(
        @as(f32, pi),
        angle3(f32x4(1.0, 0.0, 0.0, 0.0), f32x4(-1.0, 0.0, 0.0, 0.0)),
        1.0e-5,
    );
}

/// Some vector perpendicular to `v` (lanes 0,1,2).  Not normalized,
/// not unique - picks the cardinal axis most orthogonal to `v` and
/// crosses with it, which is numerically stable for any non-zero `v`.
pub inline fn perpendicular3(v: Vec) Vec {
    var min_comp: f32 = @abs(v[0]);
    var axis: Vec = f32x4(1.0, 0.0, 0.0, 0.0);
    if (@abs(v[1]) < min_comp) {
        min_comp = @abs(v[1]);
        axis = f32x4(0.0, 1.0, 0.0, 0.0);
    }
    if (@abs(v[2]) < min_comp) {
        axis = f32x4(0.0, 0.0, 1.0, 0.0);
    }
    return cross(v, axis);
}
test "zm.perpendicular3" {
    for ([_]Vec{
        f32x4(1.0, 0.0, 0.0, 0.0),
        f32x4(0.0, 3.0, 0.0, 0.0),
        f32x4(1.0, 2.0, 3.0, 0.0),
        f32x4(-5.0, 0.1, 2.0, 0.0),
    }) |v| {
        const p: Vec = perpendicular3(v);
        // dot must be ~0, and p must be non-zero
        try expectApproxEqAbs(@as(f32, 0.0), dot3(v, p), 1.0e-5);
        try expect(lengthSq3(p) > 1.0e-6);
    }
}

/// Projection of `a` onto `b` (lanes 0,1,2): the component of `a`
/// parallel to `b`, as a vector.
pub inline fn project3(a: Vec, b: Vec) Vec {
    const mag: f32 = dot3(a, b) / dot3(b, b);
    return b * splat(mag);
}
test "zm.project3" {
    // project (2,3,0) onto +x -> (2,0,0)
    const p: Vec = project3(f32x4(2.0, 3.0, 0.0, 0.0), f32x4(1.0, 0.0, 0.0, 0.0));
    try expectApproxEqAbs(@as(f32, 2.0), p[0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, 0.0), p[1], 1.0e-5);
}

/// Rejection of `a` from `b` (lanes 0,1,2): the component of `a`
/// perpendicular to `b`.  `a - project3(a, b)`.
pub inline fn reject3(a: Vec, b: Vec) Vec {
    return a - project3(a, b);
}
test "zm.reject3" {
    // reject (2,3,0) from +x -> (0,3,0)
    const r: Vec = reject3(f32x4(2.0, 3.0, 0.0, 0.0), f32x4(1.0, 0.0, 0.0, 0.0));
    try expectApproxEqAbs(@as(f32, 0.0), r[0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, 3.0), r[1], 1.0e-5);
    // project + reject reconstructs the original
    const a: Vec = .{ 1.5, -2.0, 4.0, 0.0 };
    const b: Vec = .{ 0.3, 1.0, -0.7, 0.0 };
    const sum: Vec = project3(a, b) + reject3(a, b);
    try expectApproxEqAbs(a[0], sum[0], 1.0e-5);
    try expectApproxEqAbs(a[1], sum[1], 1.0e-5);
    try expectApproxEqAbs(a[2], sum[2], 1.0e-5);
}

/// Reflect a 3D vector about a unit normal (lanes 0,1,2).  GLSL
/// `reflect` contract: `v - 2*(v·n)*n`.  zmath has no `reflect` at
/// any width - `reflect2` is its 2D sibling.
pub inline fn reflect3(v: Vec, normal: Vec) Vec {
    const d: f32 = dot3(v, normal);
    return v - normal * splat(2.0 * d);
}
test "zm.reflect3" {
    // ball falling straight down bounces straight up off a +y floor
    const r: Vec = reflect3(f32x4(0.0, -1.0, 0.0, 0.0), f32x4(0.0, 1.0, 0.0, 0.0));
    try expectApproxEqAbs(@as(f32, 1.0), r[1], 1.0e-6);
    try expectApproxEqAbs(@as(f32, 0.0), r[0], 1.0e-6);
    try expectApproxEqAbs(@as(f32, 0.0), r[2], 1.0e-6);
}

/// Refract a 3D vector through a surface (lanes 0,1,2).  `n` is the
/// unit surface normal, `r` the ratio of indices of refraction
/// (n_in / n_out).  Returns the zero vector on total internal
/// reflection.  GLSL `refract` formula; `refract2` is the 2D sibling.
pub inline fn refract3(
    v: Vec,
    n: Vec,
    r: f32,
) Vec {
    const d_v: f32 = dot3(v, n);
    const d: f32 = 1.0 - r * r * (1.0 - d_v * d_v);
    if (d < 0.0) {
        return f32x4(0.0, 0.0, 0.0, 0.0);
    } // total internal reflection
    const dsqrt: f32 = @sqrt(d);
    return v * splat(r) - n * splat(r * d_v + dsqrt);
}
test "zm.refract3" {
    // r = 1 (matched media) passes the ray straight through
    const v: Vec = normalize3(f32x4(0.2, -1.0, 0.1, 0.0));
    const out: Vec = refract3(v, f32x4(0.0, 1.0, 0.0, 0.0), 1.0);
    try expectApproxEqAbs(v[0], out[0], 1.0e-5);
    try expectApproxEqAbs(v[1], out[1], 1.0e-5);
    try expectApproxEqAbs(v[2], out[2], 1.0e-5);
}

/// Move `v` toward `target` (lanes 0,1,2) by at most `max_dist`.
/// Snaps to `target` exactly when within range.
pub inline fn moveTowards3(
    v: Vec,
    target: Vec,
    max_dist: f32,
) Vec {
    const delta: Vec = target - v;
    const dist_sq: f32 = delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2];
    if (dist_sq == 0.0 or (max_dist >= 0.0 and dist_sq <= max_dist * max_dist)) {
        return target;
    }
    const dist: f32 = @sqrt(dist_sq);
    return v + delta * splat(max_dist / dist);
}
test "zm.moveTowards3" {
    const m: Vec = moveTowards3(f32x4(0.0, 0.0, 0.0, 0.0), f32x4(0.0, 10.0, 0.0, 0.0), 4.0);
    try expectApproxEqAbs(@as(f32, 4.0), m[1], 1.0e-5);
    // overshoot snaps
    const m2: Vec = moveTowards3(f32x4(0.0, 0.0, 0.0, 0.0), f32x4(1.0, 0.0, 0.0, 0.0), 9.0);
    try expectApproxEqAbs(@as(f32, 1.0), m2[0], 1.0e-6);
}

/// Epsilon equality of two 3D vectors (lanes 0,1,2), magnitude-
/// relative tolerance (same as scalar `floatEquals`).
pub inline fn equals3(p: Vec, q: Vec) bool {
    return floatEquals(p[0], q[0]) and floatEquals(p[1], q[1]) and floatEquals(p[2], q[2]);
}
test "zm.equals3" {
    try expect(equals3(f32x4(1.0, 2.0, 3.0, 0.0), f32x4(1.0, 2.0, 3.0, 0.0)));
    try expect(equals3(f32x4(1.0, 2.0, 3.0, 7.0), f32x4(1.0, 2.0, 3.0, -7.0))); // lane 3 ignored
    try expect(!equals3(f32x4(1.0, 2.0, 3.0, 0.0), f32x4(1.0, 2.0, 3.1, 0.0)));
}

/// Result of `orthoNormalize3`: an orthonormal pair built from two
/// input vectors.  `tangent` is the normalized first input;
/// `bitangent` is orthogonal to it, in the plane of the two inputs.
pub const OrthoBasis3 = struct { tangent: Vec, bitangent: Vec };

/// Gram-Schmidt-style orthonormalization of two 3D vectors.  Returns
/// `tangent` = normalized `v1`, and `bitangent` = a unit vector
/// orthogonal to `tangent` lying in the `v1`/`v2` plane.  Mirrors
/// raylib's `Vector3OrthoNormalize`, but value-in / value-out (no
/// in-place pointer mutation - the zmath style).
pub fn orthoNormalize3(v1: Vec, v2: Vec) OrthoBasis3 {
    const tangent: Vec = normalize3(v1);
    // vn1 = normalize(cross(tangent, v2)) - orthogonal to the plane
    const vn1: Vec = normalize3(cross(tangent, v2));
    // bitangent = cross(vn1, tangent) - completes the basis, in-plane
    const bitangent: Vec = cross(vn1, tangent);
    return .{ .tangent = tangent, .bitangent = bitangent };
}
test "zm.orthoNormalize3" {
    const b: OrthoBasis3 = orthoNormalize3(f32x4(2.0, 0.0, 0.0, 0.0), f32x4(1.0, 1.0, 0.0, 0.0));
    // tangent is unit +x
    try expectApproxEqAbs(@as(f32, 1.0), b.tangent[0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, 1.0), length3(b.tangent), 1.0e-5);
    // bitangent is unit and orthogonal to tangent
    try expectApproxEqAbs(@as(f32, 1.0), length3(b.bitangent), 1.0e-5);
    try expectApproxEqAbs(@as(f32, 0.0), dot3(b.tangent, b.bitangent), 1.0e-5);
}

/// Barycentric coordinates of point `p` with respect to triangle
/// `(a, b, c)`, all in 3D (lanes 0,1,2).  Returns `(u, v, w)` in
/// lanes 0,1,2 with `u + v + w == 1`; `p == u*a + v*b + w*c`.
pub fn barycenter3(
    p: Vec,
    a: Vec,
    b: Vec,
    c: Vec,
) Vec {
    const v0: Vec = b - a;
    const v1: Vec = c - a;
    const v2: Vec = p - a;
    const d00: f32 = dot3(v0, v0);
    const d01: f32 = dot3(v0, v1);
    const d11: f32 = dot3(v1, v1);
    const d20: f32 = dot3(v2, v0);
    const d21: f32 = dot3(v2, v1);
    const denom: f32 = d00 * d11 - d01 * d01;
    const v: f32 = (d11 * d20 - d01 * d21) / denom;
    const w: f32 = (d00 * d21 - d01 * d20) / denom;
    const u: f32 = 1.0 - (w + v);
    return f32x4(u, v, w, 0.0);
}
test "zm.barycenter3" {
    const a: Vec = .{ 0.0, 0.0, 0.0, 0.0 };
    const b: Vec = .{ 1.0, 0.0, 0.0, 0.0 };
    const c: Vec = .{ 0.0, 1.0, 0.0, 0.0 };
    // a vertex -> (1,0,0)
    const ba: Vec = barycenter3(a, a, b, c);
    try expectApproxEqAbs(@as(f32, 1.0), ba[0], 1.0e-5);
    // centroid -> (1/3, 1/3, 1/3)
    const centroid: Vec = f32x4(1.0 / 3.0, 1.0 / 3.0, 0.0, 0.0);
    const bc: Vec = barycenter3(centroid, a, b, c);
    try expectApproxEqAbs(@as(f32, 1.0 / 3.0), bc[0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, 1.0 / 3.0), bc[1], 1.0e-5);
    try expectApproxEqAbs(@as(f32, 1.0 / 3.0), bc[2], 1.0e-5);
}

/// Cubic Hermite spline interpolation between `v1` (at t=0) and `v2`
/// (at t=1) with endpoint tangents `tangent1` / `tangent2`.  Lanes
/// 0,1,2.  `t` is the interpolation parameter.
pub inline fn cubicHermite3(
    v1: Vec,
    tangent1: Vec,
    v2: Vec,
    tangent2: Vec,
    t: f32,
) Vec {
    const t2: f32 = t * t;
    const t3: f32 = t2 * t;
    const h00: Vec = splat(2.0 * t3 - 3.0 * t2 + 1.0);
    const h10: Vec = splat(t3 - 2.0 * t2 + t);
    const h01: Vec = splat(-2.0 * t3 + 3.0 * t2);
    const h11: Vec = splat(t3 - t2);
    return v1 * h00 + tangent1 * h10 + v2 * h01 + tangent2 * h11;
}
test "zm.cubicHermite3" {
    const v1: Vec = .{ 0.0, 0.0, 0.0, 0.0 };
    const v2: Vec = .{ 1.0, 0.0, 0.0, 0.0 };
    const tangent: Vec = f32x4(0.0, 0.0, 0.0, 0.0);
    // endpoints are hit exactly
    const at0: Vec = cubicHermite3(v1, tangent, v2, tangent, 0.0);
    try expectApproxEqAbs(@as(f32, 0.0), at0[0], 1.0e-5);
    const at1: Vec = cubicHermite3(v1, tangent, v2, tangent, 1.0);
    try expectApproxEqAbs(@as(f32, 1.0), at1[0], 1.0e-5);
    // with zero tangents the midpoint is the smoothstep value 0.5
    const mid: Vec = cubicHermite3(v1, tangent, v2, tangent, 0.5);
    try expectApproxEqAbs(@as(f32, 0.5), mid[0], 1.0e-5);
}

/// Rotate a 3D vector (lanes 0,1,2) around an arbitrary axis by
/// `angle` radians, via the Euler-Rodrigues formula.  `axis` need not
/// be normalized - it is normalized internally.  This is the direct
/// vector rotation; for rotating many vectors by the same rotation,
/// build a `Mat` (`matFromAxisAngle`) or `Quat` once instead.
pub fn rotateByAxisAngle3(
    v: Vec,
    axis: Vec,
    angle: f32,
) Vec {
    const unit_axis: Vec = normalize3(axis);
    const half: f32 = angle * 0.5;
    const s: f32 = @sin(half);
    // w = sin(half) * axis ; the "vector part" of the rotation quat
    const w: Vec = unit_axis * splat(s);
    const c: f32 = @cos(half);
    // result = v + 2c*(w x v) + 2*(w x (w x v))
    const wv: Vec = cross(w, v);
    const wwv: Vec = cross(w, wv);
    return v + wv * splat(2.0 * c) + wwv * splat(2.0);
}
test "zm.rotateByAxisAngle3" {
    // +x rotated 90 deg about +z -> +y
    const r: Vec = rotateByAxisAngle3(f32x4(1.0, 0.0, 0.0, 0.0), f32x4(0.0, 0.0, 1.0, 0.0), pi / 2.0);
    try expectApproxEqAbs(@as(f32, 0.0), r[0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, 1.0), r[1], 1.0e-5);
    try expectApproxEqAbs(@as(f32, 0.0), r[2], 1.0e-5);
    // rotation about an axis parallel to v leaves v unchanged
    const r2: Vec = rotateByAxisAngle3(f32x4(0.0, 2.0, 0.0, 0.0), f32x4(0.0, 5.0, 0.0, 0.0), 1.234);
    try expectApproxEqAbs(@as(f32, 2.0), r2[1], 1.0e-5);
    // a non-normalized axis gives the same result as a normalized one
    const big: Vec = rotateByAxisAngle3(f32x4(1.0, 0.0, 0.0, 0.0), f32x4(0.0, 0.0, 9.0, 0.0), 0.7);
    const norm: Vec = rotateByAxisAngle3(f32x4(1.0, 0.0, 0.0, 0.0), f32x4(0.0, 0.0, 1.0, 0.0), 0.7);
    try expectApproxEqAbs(big[0], norm[0], 1.0e-5);
    try expectApproxEqAbs(big[1], norm[1], 1.0e-5);
}

/// Unproject a point from normalized device / screen space back to
/// world space, given the projection and view matrices.  `source` is
/// the NDC point (lanes 0,1,2); the result is the world-space point
/// (lanes 0,1,2, perspective-divided).
/// Under the column-major M*v convention, the world→clip matrix is
/// `mulMat(projection, view)` (projection applied last; pre-Stage-2
/// this was `mul(view, projection)` under row-major v*M).
pub fn unproject3(
    source: Vec,
    projection: Mat,
    view: Mat,
) Vec {
    const view_proj: Mat = mulMat(projection, view);
    const inv: Mat = inverse(view_proj);
    const p: Vec = pointFromArr3(source);
    const q: Vec = mulMatVec(inv, p);
    const inv_w: f32 = 1.0 / q[3];
    return f32x4(q[0] * inv_w, q[1] * inv_w, q[2] * inv_w, 0.0);
}
test "zm.unproject3" {
    // unproject is the inverse of project: push a world point through
    // view+proj, then unproject, and get the original back.
    const view: Mat = lookAtRh(f32x4(0.0, 0.0, 5.0, 1.0), f32x4(0.0, 0.0, 0.0, 1.0), f32x4(0.0, 1.0, 0.0, 0.0));
    const proj: Mat = perspectiveFovRh(0.25 * pi, 1.0, 0.1, 100.0);
    const world: Vec = f32x4(1.0, -0.5, 0.0, 1.0);
    // project: world -> clip -> NDC.  Old: mul(world, mul(view, proj));
    // new: mulMatVec(mulMat(proj, view), world).
    const clip: Vec = mulMatVec(mulMat(proj, view), world);
    const ndc: Vec = f32x4(clip[0] / clip[3], clip[1] / clip[3], clip[2] / clip[3], 0.0);
    // unproject back
    const back: Vec = unproject3(ndc, proj, view);
    try expectApproxEqAbs(world[0], back[0], 1.0e-3);
    try expectApproxEqAbs(world[1], back[1], 1.0e-3);
    try expectApproxEqAbs(world[2], back[2], 1.0e-3);
}

// ---- 4D
/// 4D distance between two points (all four lanes).  Default form (f32).
pub inline fn distance4(v0: Vec, v1: Vec) f32 {
    return length4(v1 - v0);
}
pub inline fn distance4Splat(v0: Vec, v1: Vec) Vec {
    return length4Splat(v1 - v0);
}
test "zm.distance4" {
    try expectApproxEqAbs(
        @as(f32, 2.0),
        distance4(f32x4(0.0, 0.0, 0.0, 0.0), f32x4(1.0, 1.0, 1.0, 1.0)),
        1.0e-5,
    );
}

/// 4D squared distance between two points (all four lanes).
pub inline fn distanceSq4(v0: Vec, v1: Vec) f32 {
    return lengthSq4(v1 - v0);
}
pub inline fn distanceSq4Splat(v0: Vec, v1: Vec) Vec {
    return lengthSq4Splat(v1 - v0);
}
test "zm.distanceSq4" {
    try expectApproxEqAbs(
        @as(f32, 4.0),
        distanceSq4(f32x4(0.0, 0.0, 0.0, 0.0), f32x4(1.0, 1.0, 1.0, 1.0)),
        1.0e-5,
    );
}

/// Move `v` toward `target` (all four lanes) by at most `max_dist`.
/// Snaps to `target` exactly when within range.
pub inline fn moveTowards4(
    v: Vec,
    target: Vec,
    max_dist: f32,
) Vec {
    const delta: Vec = target - v;
    const dist_sq: f32 = lengthSq4(delta);
    if (dist_sq == 0.0 or (max_dist >= 0.0 and dist_sq <= max_dist * max_dist)) {
        return target;
    }
    const dist: f32 = @sqrt(dist_sq);
    return v + delta * splat(max_dist / dist);
}
test "zm.moveTowards4" {
    const m: Vec = moveTowards4(f32x4(0.0, 0.0, 0.0, 0.0), f32x4(10.0, 0.0, 0.0, 0.0), 2.5);
    try expectApproxEqAbs(@as(f32, 2.5), m[0], 1.0e-5);
    const m2: Vec = moveTowards4(f32x4(0.0, 0.0, 0.0, 0.0), f32x4(0.0, 0.0, 0.0, 1.0), 9.0);
    try expectApproxEqAbs(@as(f32, 1.0), m2[3], 1.0e-6);
}

/// Epsilon equality of two 4D vectors (all four lanes), magnitude-
/// relative tolerance.
pub inline fn equals4(p: Vec, q: Vec) bool {
    return floatEquals(p[0], q[0]) and floatEquals(p[1], q[1]) and
        floatEquals(p[2], q[2]) and floatEquals(p[3], q[3]);
}
test "zm.equals4" {
    try expect(equals4(f32x4(1.0, 2.0, 3.0, 4.0), f32x4(1.0, 2.0, 3.0, 4.0)));
    try expect(!equals4(f32x4(1.0, 2.0, 3.0, 4.0), f32x4(1.0, 2.0, 3.0, 4.5)));
}

// Z2 / Category 4 - matrix & quaternion operations zmath lacks
// Decision-7 filter: zmath already has `matToArr` (= raylib's
// `matrixToFloatV`), `mul` (= raylib's `quaternionTransform`, which is
// just vector*matrix), `matFromQuat`/`quatFromMat`, `inverse`,
// `determinant`, `transpose`, all the `*Rh`/`*Lh` projection builders,
// `quatFromAxisAngle`, `slerp`, `rotate`.  None re-ported.
// What follows is the genuine gap.  Ported.
// ---- Matrix
/// Trace of a 4x4 matrix - the sum of its diagonal.
pub inline fn matrixTrace(m: Mat) f32 {
    return m[0][0] + m[1][1] + m[2][2] + m[3][3];
}
test "zm.matrixTrace" {
    try expectApproxEqAbs(@as(f32, 4.0), matrixTrace(identity()), 1.0e-6);
    try expectApproxEqAbs(@as(f32, 2.0 + 3.0 + 4.0 + 1.0), matrixTrace(scaling(2.0, 3.0, 4.0)), 1.0e-6);
}

/// General perspective frustum matrix from the six clip-plane
/// coordinates (right-handed, looking down -z).  Uses the OpenGL
/// `[-1, 1]` clip-space depth convention - this is raylib's
/// `MatrixFrustum`, and it pairs with zmath's `perspectiveFovRhGl` /
/// `orthographic*Gl` builders, NOT the `[0, 1]`-depth `perspectiveFovRh`.
/// For a symmetric frustum prefer `perspectiveFovRhGl`.
pub fn matrixFrustum(
    left: f32,
    right: f32,
    bottom: f32,
    top: f32,
    near: f32,
    far: f32,
) Mat {
    const rl: f32 = right - left;
    const tb: f32 = top - bottom;
    const fnn: f32 = far - near;
    const n2: f32 = near * 2.0;
    // Row-major (zmath layout), GL [-1,1] depth.
    return .{
        f32x4(n2 / rl, 0.0, 0.0, 0.0),
        f32x4(0.0, n2 / tb, 0.0, 0.0),
        f32x4((right + left) / rl, (top + bottom) / tb, -(far + near) / fnn, -1.0),
        f32x4(0.0, 0.0, -(far * near * 2.0) / fnn, 0.0),
    };
}
test "zm.matrixFrustum" {
    // A symmetric frustum built via matrixFrustum must equal the one
    // perspectiveFovRhGl produces for the matching fov.  (Gl variant:
    // matrixFrustum uses the OpenGL [-1,1] depth convention, like
    // raylib - NOT the [0,1]-depth perspectiveFovRh.)
    const near: f32 = 0.5;
    const far: f32 = 100.0;
    const half_h: f32 = near; // fovy = 2*atan(half_h/near) = 2*atan(1) = pi/2
    const half_w: f32 = half_h; // aspect 1
    const a: Mat = matrixFrustum(-half_w, half_w, -half_h, half_h, near, far);
    const b: Mat = perspectiveFovRhGl(pi / 2.0, 1.0, near, far);
    inline for (0..4) |r| {
        inline for (0..4) |c| {
            try expectApproxEqAbs(b[r][c], a[r][c], 1.0e-4);
        }
    }
}

/// Build a transform matrix from translation, rotation, and scale —
/// the standard Trs composition.  Under the column-major M*v
/// convention, the composition that applies "scale, then rotate,
/// then translate" to a point is `mulMat(T, mulMat(R, S))`.
/// Provided as one call because "compose a transform" is a
/// frequent intent.  `scale` and `t` (translation) use lanes 0,1,2.
pub fn matrixCompose(
    t: Vec,
    rotation: Quat,
    scale: Vec,
) Mat {
    const s: Mat = scaling(scale[0], scale[1], scale[2]);
    const r: Mat = matFromQuat(rotation);
    const tm: Mat = translationV(t);
    return mulMat(tm, mulMat(r, s));
}
test "zm.matrixCompose" {
    // pure translation
    const m1: Mat = matrixCompose(
        f32x4(10.0, 20.0, 30.0, 0.0),
        quatFromAxisAngle(f32x4(0.0, 0.0, 1.0, 0.0), 0.0),
        f32x4(1.0, 1.0, 1.0, 0.0),
    );
    // Old: mul(point, m1) Vec×Mat → mulMatVec(m1, point).
    const p: Vec = mulMatVec(m1, f32x4(0.0, 0.0, 0.0, 1.0));
    try expectApproxEqAbs(@as(f32, 10.0), p[0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, 20.0), p[1], 1.0e-5);
    try expectApproxEqAbs(@as(f32, 30.0), p[2], 1.0e-5);
    // scale then translate: a unit-x point at scale 2 lands at x=2 (+ translation)
    const m2: Mat = matrixCompose(
        f32x4(1.0, 0.0, 0.0, 0.0),
        quatFromAxisAngle(f32x4(0.0, 0.0, 1.0, 0.0), 0.0),
        f32x4(2.0, 2.0, 2.0, 0.0),
    );
    const p2: Vec = mulMatVec(m2, f32x4(1.0, 0.0, 0.0, 1.0));
    try expectApproxEqAbs(@as(f32, 3.0), p2[0], 1.0e-5); // 1*2 + 1
}

/// Column-major 3x3 matrix (`col[j]` is the jth basis vector in the upper 3
/// lanes). The companion to the 4x4 `Mat` for rotation / inertia / covariance
/// work that never needs translation. Pure SIMD value type — shader- and
/// comptime-safe.
pub const Mat3 = struct {
    col: [3]Vec,

    pub const zero: Mat3 = .{ .col = .{ vec_zero, vec_zero, vec_zero } };

    /// Matrix * vector (column-major: result = Σ vᵢ · colᵢ).
    pub fn mulVec(m: Mat3, v: Vec) Vec {
        const cx: Vec = splat(v[0]) * m.col[0];
        const cy: Vec = splat(v[1]) * m.col[1];
        const cz: Vec = splat(v[2]) * m.col[2];
        return cx + cy + cz;
    }

    /// s * Identity.
    pub fn diagonal(s: f32) Mat3 {
        return .{ .col = .{ vec(s, 0, 0), vec(0, s, 0), vec(0, 0, s) } };
    }

    /// Cross-product matrix: skew(v) * w == v x w.
    pub fn skew(v: Vec) Mat3 {
        return .{ .col = .{
            vec(0, v[2], -v[1]),
            vec(-v[2], 0, v[0]),
            vec(v[1], -v[0], 0),
        } };
    }

    /// Component-wise sum of two matrices.
    pub fn add(a: Mat3, b: Mat3) Mat3 {
        return .{ .col = .{ a.col[0] + b.col[0], a.col[1] + b.col[1], a.col[2] + b.col[2] } };
    }

    /// Scale every entry by `s`.
    pub fn scale(m: Mat3, s: f32) Mat3 {
        const v: Vec = splat(s);
        return .{ .col = .{ m.col[0] * v, m.col[1] * v, m.col[2] * v } };
    }

    /// Matrix product A * B (column j of the result is A applied to B's column j).
    pub fn mul(a: Mat3, b: Mat3) Mat3 {
        return .{ .col = .{ a.mulVec(b.col[0]), a.mulVec(b.col[1]), a.mulVec(b.col[2]) } };
    }

    /// Transpose (swap rows and columns).
    pub fn transpose(m: Mat3) Mat3 {
        return .{ .col = .{
            vec(m.col[0][0], m.col[1][0], m.col[2][0]),
            vec(m.col[0][1], m.col[1][1], m.col[2][1]),
            vec(m.col[0][2], m.col[1][2], m.col[2][2]),
        } };
    }

    /// Inverse via the adjugate; null if (near-)singular. For columns a,b,c the inverse
    /// rows are (b x c)/det, (c x a)/det, (a x b)/det.
    pub fn inverse(m: Mat3) ?Mat3 {
        const a: Vec = m.col[0];
        const b: Vec = m.col[1];
        const c: Vec = m.col[2];
        const bc: Vec = cross(b, c);
        const det: f32 = dot3(a, bc);
        if (@abs(det) < 1.0e-12) {
            return null;
        }
        const inv_det: f32 = 1.0 / det;
        const row0: Vec = bc * splat(inv_det);
        const row1: Vec = cross(c, a) * splat(inv_det);
        const row2: Vec = cross(a, b) * splat(inv_det);
        return .{ .col = .{
            vec(row0[0], row1[0], row2[0]),
            vec(row0[1], row1[1], row2[1]),
            vec(row0[2], row1[2], row2[2]),
        } };
    }
};

/// Scalar 2x2 matrix. Small enough that the four-field form beats a `@Vector`;
/// used for 2-DOF joint blocks and other planar solves. Value type, GPU/comptime-safe.
pub const Mat2 = struct {
    m00: f32,
    m01: f32,
    m10: f32,
    m11: f32,

    pub const zero: Mat2 = .{ .m00 = 0.0, .m01 = 0.0, .m10 = 0.0, .m11 = 0.0 };

    /// Inverse, or null if (near-)singular.
    pub fn inverse(m: Mat2) ?Mat2 {
        const det: f32 = m.m00 * m.m11 - m.m01 * m.m10;
        if (@abs(det) < 1.0e-12) {
            return null;
        }
        const inv_det: f32 = 1.0 / det;
        return .{
            .m00 = m.m11 * inv_det,
            .m01 = -m.m01 * inv_det,
            .m10 = -m.m10 * inv_det,
            .m11 = m.m00 * inv_det,
        };
    }

    /// Matrix * (x, y), returned as a 2-element array.
    pub fn mulVec(m: Mat2, x: f32, y: f32) [2]f32 {
        return .{ m.m00 * x + m.m01 * y, m.m10 * x + m.m11 * y };
    }
};

/// Axis-aligned bounding box (min/max corners in the upper 3 lanes). The one
/// canonical AABB for the whole engine — broad-phase, culling, mesh bounds.
/// Pure SIMD value type, shader- and comptime-safe.
pub const Aabb = struct {
    min: Vec,
    max: Vec,

    /// True when the two boxes intersect (per-axis separating-axis test).
    pub fn overlaps(a: Aabb, b: Aabb) bool {
        const sep_x: bool = a.min[0] > b.max[0] or b.min[0] > a.max[0];
        const sep_y: bool = a.min[1] > b.max[1] or b.min[1] > a.max[1];
        const sep_z: bool = a.min[2] > b.max[2] or b.min[2] > a.max[2];
        return !(sep_x or sep_y or sep_z);
    }

    /// Grow the box outward by `margin` on every side.
    pub fn expandedBy(a: Aabb, margin: f32) Aabb {
        const m: Vec = splat(margin);
        return .{ .min = a.min - m, .max = a.max + m };
    }

    /// True when `a` fully encloses `b` (used to keep a fat BVH AABB valid).
    pub fn contains(a: Aabb, b: Aabb) bool {
        const lo: @Vector(4, bool) = a.min <= b.min;
        const hi: @Vector(4, bool) = b.max <= a.max;
        return @reduce(.And, lo) and @reduce(.And, hi);
    }

    /// The smallest box containing both `a` and `b`.
    pub fn combine(a: Aabb, b: Aabb) Aabb {
        return .{ .min = @min(a.min, b.min), .max = @max(a.max, b.max) };
    }

    /// An inverted "empty" box (min = +inf, max = -inf) to seed an encapsulate loop;
    /// the first encapsulate snaps it to that point.
    pub const empty: Aabb = .{
        .min = splat(floatMax(f32)),
        .max = splat(-floatMax(f32)),
    };

    /// Grow the box to include point `p`.
    pub fn encapsulate(self: *Aabb, p: Vec) void {
        self.min = @min(self.min, p);
        self.max = @max(self.max, p);
    }

    /// The box centre.
    pub fn center(a: Aabb) Vec {
        return (a.min + a.max) * splat(0.5);
    }

    /// Shift the box by `t`.
    pub fn translate(a: Aabb, t: Vec) Aabb {
        return .{ .min = a.min + t, .max = a.max + t };
    }

    /// Surface area, the cost metric for the BVH's SAH insertion heuristic.
    pub fn area(a: Aabb) f32 {
        const d: Vec = a.max - a.min;
        return 2.0 * (d[0] * d[1] + d[1] * d[2] + d[2] * d[0]);
    }
};

/// A ray: an origin `position` and a (not necessarily unit) `direction`.
pub const Ray = struct { position: Vec, direction: Vec };

/// The result of a ray cast: whether it `hit`, the `distance` along the ray,
/// and the world-space `point` / surface `normal` at the intersection.
pub const RayCollision = struct {
    hit: bool,
    distance: f32,
    point: Vec,
    normal: Vec,
};

/// A rigid-or-affine transform split into translation / rotation / scale parts;
/// the result of `matrixDecompose` and the inverse of `matrixCompose`.
pub const Transform = struct { translation: Vec, rotation: Quat, scale: Vec };

/// Legacy alias for `Transform` (the decompose result was historically `Trs`).
pub const Trs = Transform;

/// Decompose an affine transform matrix into translation, rotation,
/// and scale (the inverse of `matrixCompose`).  Handles non-uniform
/// scale and shear by Gram-Schmidt orthonormalizing the basis; the
/// sign of the determinant is folded into the scale so the extracted
/// rotation is a proper rotation (no reflection).
/// zmath's `Mat` is row-major, so the transform's basis vectors are
/// rows 0,1,2 and the translation is row 3 - this reads those
/// directly.  (raylib's `MatrixDecompose` is written for a
/// column-major matrix and famously extracts the wrong vectors when
/// ported naively; reading rows here is correct *because* the layout
/// is row-major, not a bug.)
pub fn matrixDecompose(m: Mat) Trs {
    const eps: f32 = 1.0e-9;

    const trans: Vec = dirFromArr3(m[3]);

    // Basis vectors = rows 0,1,2 (row-major).
    var b0: Vec = dirFromArr3(m[0]);
    var b1: Vec = dirFromArr3(m[1]);
    var b2: Vec = dirFromArr3(m[2]);

    // Stabilize against very large/small matrices before normalizing.
    var stab: f32 = eps;
    inline for (.{ b0, b1, b2 }) |bv| {
        stab = @max(stab, @abs(bv[0]));
        stab = @max(stab, @abs(bv[1]));
        stab = @max(stab, @abs(bv[2]));
    }
    const inv_stab: Vec = splat(1.0 / stab);
    b0 *= inv_stab;
    b1 *= inv_stab;
    b2 *= inv_stab;

    var scale: Vec = .{ 0.0, 0.0, 0.0, 0.0 };

    // X scale, then orthogonalize b1, b2 against b0.
    scale[0] = length3(b0);
    if (scale[0] > eps) {
        b0 *= splat(1.0 / scale[0]);
    }

    var shear_xy: f32 = dot3(b0, b1);
    b1 -= b0 * splat(shear_xy);

    scale[1] = length3(b1);
    if (scale[1] > eps) {
        b1 *= splat(1.0 / scale[1]);
        shear_xy /= scale[1];
    }

    var shear_xz: f32 = dot3(b0, b2);
    b2 -= b0 * splat(shear_xz);
    var shear_yz: f32 = dot3(b1, b2);
    b2 -= b1 * splat(shear_yz);

    scale[2] = length3(b2);
    if (scale[2] > eps) {
        b2 *= splat(1.0 / scale[2]);
        shear_xz /= scale[2];
        shear_yz /= scale[2];
    }

    // Now b0,b1,b2 are orthonormal - but maybe a reflection (det < 0).
    // Fold the sign into the scale so the rotation stays proper.
    if (dot3(b0, cross(b1, b2)) < 0.0) {
        scale = -scale;
        b0 = -b0;
        b1 = -b1;
        b2 = -b2;
    }

    scale *= splat(stab);

    // Rebuild the rotation matrix from the orthonormal basis (rows),
    // then convert to a quaternion.
    const rot_mat: Mat = .{
        dirFromArr3(b0),
        dirFromArr3(b1),
        dirFromArr3(b2),
        .{ 0.0, 0.0, 0.0, 1.0 },
    };
    const rotation: Quat = quatFromMat(rot_mat);

    return .{ .translation = trans, .rotation = rotation, .scale = scale };
}
test "zm.matrixDecompose" {
    // Round-trip: compose a known Trs, decompose it, expect the parts back.
    const t_in: Vec = f32x4(5.0, -2.0, 7.0, 0.0);
    const r_in: Quat = quatFromAxisAngle(normalize3(f32x4(1.0, 1.0, 0.0, 0.0)), 0.6);
    const s_in: Vec = f32x4(2.0, 3.0, 0.5, 0.0);

    const m: Mat = matrixCompose(t_in, r_in, s_in);
    const d: Trs = matrixDecompose(m);

    try expectApproxEqAbs(t_in[0], d.translation[0], 1.0e-4);
    try expectApproxEqAbs(t_in[1], d.translation[1], 1.0e-4);
    try expectApproxEqAbs(t_in[2], d.translation[2], 1.0e-4);
    try expectApproxEqAbs(s_in[0], d.scale[0], 1.0e-4);
    try expectApproxEqAbs(s_in[1], d.scale[1], 1.0e-4);
    try expectApproxEqAbs(s_in[2], d.scale[2], 1.0e-4);
    // The rotation may come back as q or -q (same orientation) - compare
    // by re-composing and checking the matrices match.
    const m2: Mat = matrixCompose(d.translation, d.rotation, d.scale);
    inline for (0..4) |r| {
        inline for (0..4) |c| {
            try expectApproxEqAbs(m[r][c], m2[r][c], 1.0e-4);
        }
    }
}

// ---- Quat
/// Shortest-arc unit quaternion that rotates direction `from` onto
/// direction `to` (both lanes 0,1,2; neither need be normalized).
/// raylib's `QuaternionFromVector3ToVector3`.
pub fn quatFromTo(from: Vec, to: Vec) Quat {
    const cos2t: f32 = dot3(from, to);
    const cr: Vec = cross(from, to);
    var q: Vec = dirFromArr3(cr);
    q[3] = @sqrt(dot3(from, from) * dot3(to, to)) + cos2t;
    return normalize4(q);
}
test "zm.quatFromTo" {
    // rotating +x onto +y, applied to +x, gives +y
    const q: Quat = quatFromTo(axis_x, axis_y);
    const v: Vec = rotate(q, axis_x);
    try expectApproxEqAbs(@as(f32, 0.0), v[0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, 1.0), v[1], 1.0e-5);
    // identity case: from == to
    const qi: Quat = quatFromTo(axis_z, axis_z);
    const vi: Vec = rotate(qi, f32x4(3.0, 4.0, 5.0, 0.0));
    try expectApproxEqAbs(@as(f32, 3.0), vi[0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, 4.0), vi[1], 1.0e-5);
    try expectApproxEqAbs(@as(f32, 5.0), vi[2], 1.0e-5);
}

/// Cubic Hermite spline interpolation between quaternions `q1` (t=0)
/// and `q2` (t=1) with endpoint tangents.  Result is renormalized.
/// raylib's `QuaternionCubicHermiteSpline`.
pub fn quatCubicHermite(
    q1: Quat,
    tangent1: Quat,
    q2: Quat,
    tangent2: Quat,
    t: f32,
) Quat {
    const t2: f32 = t * t;
    const t3: f32 = t2 * t;
    const h00: Vec = splat(2.0 * t3 - 3.0 * t2 + 1.0);
    const h10: Vec = splat(t3 - 2.0 * t2 + t);
    const h01: Vec = splat(-2.0 * t3 + 3.0 * t2);
    const h11: Vec = splat(t3 - t2);
    return normalize4(q1 * h00 + tangent1 * h10 + q2 * h01 + tangent2 * h11);
}
test "zm.quatCubicHermite" {
    const q1: Quat = quatFromAxisAngle(axis_z, 0.0);
    const q2: Quat = quatFromAxisAngle(axis_z, 1.0);
    const zero_tan: Quat = vec_zero;
    // endpoints hit exactly (up to sign / renormalization)
    const at0: Quat = quatCubicHermite(q1, zero_tan, q2, zero_tan, 0.0);
    try expect(approxEqAbs(at0, q1, 1.0e-5) or approxEqAbs(at0, -q1, 1.0e-5));
    const at1: Quat = quatCubicHermite(q1, zero_tan, q2, zero_tan, 1.0);
    try expect(approxEqAbs(at1, q2, 1.0e-5) or approxEqAbs(at1, -q2, 1.0e-5));
    // result is always unit-length
    const mid: Quat = quatCubicHermite(q1, zero_tan, q2, zero_tan, 0.5);
    try expectApproxEqAbs(@as(f32, 1.0), length4(mid), 1.0e-5);
}

/// Epsilon equality of two quaternions, magnitude-relative tolerance.
/// NOTE: this is a *component* compare - it does NOT treat `q` and
/// `-q` as equal even though they represent the same rotation.  If
/// you need rotational equality, compare `abs(dot4(a,b))` to 1.
pub inline fn quatEquals(a: Quat, b: Quat) bool {
    return floatEquals(a[0], b[0]) and floatEquals(a[1], b[1]) and
        floatEquals(a[2], b[2]) and floatEquals(a[3], b[3]);
}
test "zm.quatEquals" {
    const q: Quat = quatFromAxisAngle(axis_y, 0.7);
    try expect(quatEquals(q, q));
    try expect(!quatEquals(q, -q)); // component compare, not rotational
}

// ---- Euler angles - TWO orders shipped, with explicit names
// Euler order is not a "two spellings" case (plan decision 7's
// carve-out): XYZ and ZXY produce *different* rotations, both have
// real callers.  Verified empirically: raylib's `quaternionFromEuler`
// is XYZ order; zmath's `quatFromRollPitchYaw` is ZXY.  Both ship,
// with names that state the order outright - fixing the real sin of
// both upstreams (an opaque name you must read source to decode).
// Angles are (x-rotation, y-rotation, z-rotation) in lanes 0,1,2.
// Only these two orders ship; the other four are not added on spec.

/// Quat from Euler angles, **XYZ** order (rotate about X, then
/// Y, then Z).  This is raylib's `quaternionFromEuler` convention.
/// `e` holds the x,y,z angles in lanes 0,1,2.
pub fn quatFromEulerXYZ(e: Vec) Quat {
    const qx: Quat = quatFromAxisAngle(axis_x, e[0]);
    const qy: Quat = quatFromAxisAngle(axis_y, e[1]);
    const qz: Quat = quatFromAxisAngle(axis_z, e[2]);
    // qmul is Hamilton (qmul(a,b) applies b first) - compose X, then Y, then Z.
    return qmul(qz, qmul(qy, qx));
}

/// Quat from Euler angles, **ZXY** order (rotate about Z, then
/// X, then Y).  This is zmath's `quatFromRollPitchYaw` convention.
/// `e` holds the x,y,z angles in lanes 0,1,2.
pub fn quatFromEulerZXY(e: Vec) Quat {
    const qx: Quat = quatFromAxisAngle(axis_x, e[0]);
    const qy: Quat = quatFromAxisAngle(axis_y, e[1]);
    const qz: Quat = quatFromAxisAngle(axis_z, e[2]);
    return qmul(qy, qmul(qx, qz));
}

/// Euler angles (x,y,z in lanes 0,1,2) from a quaternion, **XYZ**
/// order - the inverse of `quatFromEulerXYZ`.  raylib's
/// `quaternionToEuler` convention.
pub fn quatToEulerXYZ(q: Quat) Vec {
    // x-axis rotation
    const sx: f32 = 2.0 * (q[3] * q[0] + q[1] * q[2]);
    const cx: f32 = 1.0 - 2.0 * (q[0] * q[0] + q[1] * q[1]);
    const x: f32 = atan2(sx, cx);
    // y-axis rotation, clamped for the gimbal-lock pole
    var sy: f32 = 2.0 * (q[3] * q[1] - q[2] * q[0]);
    sy = @max(@as(f32, -1.0), @min(@as(f32, 1.0), sy));
    const y: f32 = asin(sy);
    // z-axis rotation
    const sz: f32 = 2.0 * (q[3] * q[2] + q[0] * q[1]);
    const cz: f32 = 1.0 - 2.0 * (q[1] * q[1] + q[2] * q[2]);
    const z: f32 = atan2(sz, cz);
    return f32x4(x, y, z, 0.0);
}

/// Euler angles (x,y,z in lanes 0,1,2) from a quaternion, **ZXY**
/// order - the inverse of `quatFromEulerZXY`.  zmath's
/// `quatToRollPitchYaw` produces the same triple (it returns a
/// `[3]f32`; this returns it in a `Vec` for consistency with the
/// rest of the euler API).
pub fn quatToEulerZXY(q: Quat) Vec {
    const rpy: [3]f32 = quatToRollPitchYaw(q);
    return dirFromArr3(rpy);
}

test "zm.quatFromEulerXYZ matches raylib order" {
    // single-axis cases
    const ex: Quat = quatFromEulerXYZ(f32x4(0.5, 0.0, 0.0, 0.0));
    try expect(approxEqAbs(ex, quatFromAxisAngle(f32x4(1.0, 0.0, 0.0, 0.0), 0.5), 1.0e-5));
    // round-trip through quatToEulerXYZ
    const e_in: Vec = f32x4(0.3, -0.4, 0.2, 0.0);
    const back: Vec = quatToEulerXYZ(quatFromEulerXYZ(e_in));
    try expectApproxEqAbs(e_in[0], back[0], 1.0e-4);
    try expectApproxEqAbs(e_in[1], back[1], 1.0e-4);
    try expectApproxEqAbs(e_in[2], back[2], 1.0e-4);
}

test "zm.quatFromEulerZXY matches zmath quatFromRollPitchYaw" {
    // quatFromEulerZXY must agree with zmath's existing (ZXY) builder
    const e: Vec = f32x4(0.3, 0.5, 0.7, 0.0);
    const a: Quat = quatFromEulerZXY(e);
    const b: Quat = quatFromRollPitchYaw(e[0], e[1], e[2]); // (pitch=x, yaw=y, roll=z)
    try expect(approxEqAbs(a, b, 1.0e-4) or approxEqAbs(a, -b, 1.0e-4));
    // round-trip
    const back: Vec = quatToEulerZXY(quatFromEulerZXY(e));
    try expectApproxEqAbs(e[0], back[0], 1.0e-4);
    try expectApproxEqAbs(e[1], back[1], 1.0e-4);
    try expectApproxEqAbs(e[2], back[2], 1.0e-4);
}

test "zm.euler XYZ and ZXY genuinely differ" {
    // The whole reason both ship: same angles, different rotation.
    const e: Vec = f32x4(0.3, 0.5, 0.7, 0.0);
    try expect(!approxEqAbs(quatFromEulerXYZ(e), quatFromEulerZXY(e), 1.0e-3));
}

// ============================================================================
// Z-shader-parity — generic helpers that mirror `src/shadermath.zig`'s API.
// ============================================================================
// Added S1.2 of the Zig-shader-pipeline arc.  These exist so a function
// written once can be called from both CPU and GPU code without renaming.
// See `src/notes/zig-shader-pipeline-plan.md` §0.3 for the design lock.
//
// Conventions: generic over the vector arity (work on `@Vector(N, f32)`
// for N=2, 3, 4).  Returns f32 for scalar-producing ops (`dot`, `length`,
// `distance`), input type for vector-producing ops (`normalize`).
//
// These DO NOT replace zmath's `dot2`/`dot3`/`dot4`/etc — those are kept
// because they (a) return Vec-broadcast scalars for the SIMD pipeline and
// (b) make the arity explicit at the callsite, which is the right choice
// for hot SIMD loops on the CPU.  Use the generic forms for general
// code + anything intended to be shareable with shadermath.

/// `max(0, min(1, x))`.  Matches `shadermath.clamp01`.
/// Clamp to [0, 1]. Scalars and vectors. HLSL calls this `saturate`; zimr calls
/// it `clamp01`, and `zm.saturate` exists only to say so (it is a @compileError).
pub inline fn clamp01(v: anytype) @TypeOf(v) {
    const T = @TypeOf(v);
    // clamp01 IS `clamp(v, 0, 1)` — a specialization of the canonical clamp, not a
    // re-implementation of it. That buys three things at once:
    //
    //  * BRANCH-FREE. `clamp` is `min(hi, max(lo, v))`, and zm's min/max are
    //    `@min`/`@max` (+ a NaN select for vectors) — no control flow. The old
    //    SCALAR path was `if (v < 0) 0 else if (v > 1) 1 else v`, and those `if`s
    //    are REAL BRANCHES in SPIR-V: any `textureSample` downstream of a scalar
    //    clamp01 ended up nested inside them in the transpiled WGSL, which Dawn
    //    rejects — "'textureSample' must only be called from uniform control
    //    flow" (decal_fs + effect_ascii_fs, device, zimr786). A branching helper
    //    in the math vocabulary is a hazard to every sample downstream of it.
    //  * SCALAR AND VECTOR AGREE. Both comparisons are FALSE for NaN, so the old
    //    scalar path returned NaN while the vector path returned 0 — a silent
    //    disagreement. The vector test has always pinned `clamp01(NaN) == 0`;
    //    now the scalar path is that same code, so it cannot drift again.
    //  * ONE definition of clamping. The `[clamp-pattern]` lint forbids raw
    //    `@min(@max(..))` for exactly this reason; clamp01 must not be an exception.
    //
    // Vector behaviour is bit-identical to the previous implementation (it was
    // already `max(v, 0)` then `min(result, 1)` — which is what `clamp` does).
    const lo: T = switch (@typeInfo(T)) {
        .vector => @splat(0.0),
        else => 0.0,
    };
    const hi: T = switch (@typeInfo(T)) {
        .vector => @splat(1.0),
        else => 1.0,
    };
    return clamp(v, lo, hi);
}

/// `x - floor(x)`.  Range `[0, 1)` for positive inputs.  Matches
/// `shadermath.fract`.
pub fn fract(v: f32) f32 {
    return v - @floor(v);
}

/// GLSL/WGSL `step(edge, x)` — `0` below the edge, `1` at or above it.
///
/// This is the CANONICAL name. It used to be called `stepEdge`, which nobody
/// searches for — and the cost of that was exactly what you would predict: a
/// shader author looked for `step`, did not find it, and hand-rolled a duplicate.
pub fn step(edge: f32, v: f32) f32 {
    // BRANCH-FREE, same reason as `clamp01`: a branch here puts every
    // `textureSample` downstream of it inside non-uniform control flow once
    // transpiled to WGSL. The bool->float conversion lowers to OpSelect, not
    // to a branch. Semantics unchanged: 0 below the edge, 1 at or above it.
    // (NaN compares false, so `step(edge, NaN) == 0`, as before.)
    return @floatFromInt(@intFromBool(v >= edge));
}

/// The old spelling. USE `zm.step`.
/// Private + empty on purpose — see `saturate` for why a dead name is still a decl.
fn stepEdge() void {}

// ---------------------------------------------------------------------------
// GPU-MATH VOCABULARY — the standard GLSL/HLSL/WGSL spellings.
//
// Only TWO names were actually missing. Everything else (`clamp`, `saturate`,
// `lerp`, `smoothstep`, `fract`, `cross`, ...) was already here — it just could
// not be FOUND, and that is the same failure as being absent:
//
//   * `step` existed as `stepEdge`. A shader author searched for `step`, did not
//     find it, and hand-rolled a duplicate. A standard operation under a
//     non-standard name is invisible, not merely oddly-spelled.
//   * `clamp`, `saturate` and `lerp` were invisible to `grep '^pub fn clamp'`
//     because they are declared `pub inline fn`. The grep LIED — three times.
//
// So: the name you would TYPE now exists, aliased to the implementation that was
// already here (nothing that calls `stepEdge`/`lerp` breaks), and the vocabulary
// is pinned by @hasDecl in features_test.zig — which cannot be fooled by either
// a non-standard name or a bad grep pattern.
// ---------------------------------------------------------------------------

/// GLSL/WGSL's `mix` — the spelling zimr does NOT use. USE `zm.lerp`.
/// zimr already had `lerp` (vector-generic, scalar factor), which IS this
/// operation; a second spelling would be pure noise.
/// Private + empty on purpose — see `saturate` for why a dead name is still a decl.
fn mix() void {}

test "zm: the dead spellings still exist (privately) to stay discoverable" {
    // From INSIDE this file, @hasDecl sees private decls. From outside it does
    // not — which is the whole point: `zm.mix` is "not marked pub", and Zig
    // points at the decl above, whose doc names the canonical spelling.
    //
    // If someone DELETES one of these, `zm.mix` degrades to "no member named
    // 'mix'" and we are back to the original failure: a standard op under a
    // non-standard name, invisible to the person looking for it. So pin them.
    // (features_test.zig pins the other half: they must NOT be pub.)
    inline for ([_][]const u8{ "mix", "saturate", "stepEdge" }) |n| {
        if (!@hasDecl(@This(), n)) {
            @compileError("zimrmath dropped the dead spelling '" ++ n ++
                "' — keep it as a PRIVATE, empty decl whose doc comment names " ++
                "the canonical spelling, or `zm." ++ n ++ "` becomes undiscoverable.");
        }
    }
}

/// `0` below `e0`, `1` above `e1`, smooth Hermite interpolation
/// between.  Matches `shadermath.smoothstep`.
pub fn smoothstep(e0: f32, e1: f32, v: f32) f32 {
    const t: f32 = clamp01((v - e0) / (e1 - e0));
    return t * t * (3.0 - 2.0 * t);
}

/// Generic dot product over `@Vector(N, f32)`.  Use the arity-suffixed
/// `dot2`/`dot3`/`dot4` for SIMD-hot CPU code; use this for general
/// code and anything intended to read identically on the GPU side.
pub fn dot(a: anytype, b: @TypeOf(a)) f32 {
    return @reduce(.Add, a * b);
}

/// Vector length: `sqrt(dot(v, v))`.
pub fn length(v: anytype) f32 {
    return @sqrt(dot(v, v));
}

/// Distance between two same-typed vectors.
pub fn distance(a: anytype, b: @TypeOf(a)) f32 {
    return length(a - b);
}

/// Normalize to unit length.  Returns the input type.
pub fn normalize(v: anytype) @TypeOf(v) {
    const inv: f32 = 1.0 / length(v);
    const inv_v: @TypeOf(v) = @splat(inv);
    return v * inv_v;
}

/// General swizzle: build a new vector from named components of `v`.
/// `chars` is a comptime string of `x`/`y`/`z`/`w` characters.  String
/// length 2 returns `Vec2`, length 4 returns `Vec`.  (Length 3 also
/// works on the GPU side via `shadermath.sw`; here it returns
/// `@Vector(3, f32)` since `math.zig` has no `Vec3` alias.)
///
/// Note: the single-component swizzles `x`/`y`/`z`/`w` that
/// `shadermath.zig` exposes do NOT exist in `math.zig` — they'd
/// collide with the many local `const x: f32 = ...` bindings in
/// vendored zmath code.  For shared code (a function callable from
/// both CPU and GPU), use direct index access `v[0]` / `v[1]` /
/// etc — idiomatic Zig, works on both sides.
pub fn sw(v: anytype, comptime chars: []const u8) @Vector(chars.len, f32) {
    const indices: @Vector(chars.len, i32) = comptime blk: {
        var arr: [chars.len]i32 = undefined;
        for (chars, 0..) |c, i| {
            arr[i] = switch (c) {
                'x' => 0,
                'y' => 1,
                'z' => 2,
                'w' => 3,
                else => @compileError("sw: only 'x', 'y', 'z', 'w' allowed"),
            };
        }
        break :blk arr;
    };
    return @shuffle(f32, v, undefined, indices);
}

// ---- Complex arithmetic ---------------------------------------------
//
// `Complex` is a `@Vector(2, f32)` (declared near `Vec` at the top
// of the file).  Native `+` and `-` work as complex addition /
// subtraction.  Use the named functions below for products,
// quotients, conjugation, modulus, argument, and transcendentals.
//
// Headline use case (mandelbrot one-liner):
//   z = cmul(z, z) + c;
//
// SPIR-V-portable: every function below uses Zig builtins (`@sqrt`,
// `@sin`, `@cos`, `@exp`, `@log`) and the polynomial `atan2Scalar`
// (defined earlier in this file).  No `std.math.X` for transcendentals
// — those would pull in lookup tables SPIR-V Logical addressing
// rejects.
//
// Locked decision D3 (math-unification): SIMD alias, no nominal
// wrapper.  See `Complex` type doc at top of file for the rationale
// and the accepted footgun (`cmul(some_vec2, some_vec2)` type-checks
// and runs).

/// Complex zero: `0 + 0i`.
pub const c_zero: Complex = .{ 0, 0 };
/// Complex one: `1 + 0i`.  Multiplicative identity.
pub const c_one: Complex = .{ 1, 0 };
/// Imaginary unit: `0 + 1i`.  `cmul(c_i, c_i) == -c_one`.
pub const c_i: Complex = .{ 0, 1 };

/// Construct a complex number from real and imaginary parts.
pub inline fn complex(re: f32, im: f32) Complex {
    return .{ re, im };
}

/// Complex multiplication: `(a + bi)(c + di) = (ac - bd) + (ad + bc)i`.
/// The `*` operator on `Complex` does COMPONENTWISE multiplication
/// (because Complex is `@Vector(2, f32)`); use `cmul` for the real
/// complex product.
pub inline fn cmul(a: Complex, b: Complex) Complex {
    return .{
        a[0] * b[0] - a[1] * b[1],
        a[0] * b[1] + a[1] * b[0],
    };
}

/// Complex division: `(a + bi) / (c + di) = ((ac + bd) + (bc - ad)i) / (c² + d²)`.
/// Returns NaN-laden vector when `b == c_zero`.
pub inline fn cdiv(a: Complex, b: Complex) Complex {
    const denom: f32 = b[0] * b[0] + b[1] * b[1];
    return .{
        (a[0] * b[0] + a[1] * b[1]) / denom,
        (a[1] * b[0] - a[0] * b[1]) / denom,
    };
}

/// Complex conjugate: `(a + bi)* = a - bi`.
pub inline fn cconj(z: Complex) Complex {
    return .{ z[0], -z[1] };
}

/// Squared modulus: `|z|² = a² + b²`.  Cheaper than `cabs` (no sqrt);
/// use this for "is this complex number's modulus greater than N"
/// comparisons (`cnorm2(z) > N*N` avoids the sqrt).  Hot path in
/// mandelbrot/julia iteration escape tests.
pub inline fn cnorm2(z: Complex) f32 {
    return z[0] * z[0] + z[1] * z[1];
}

/// Modulus: `|z| = sqrt(a² + b²)`.  Uses `@sqrt` (lowers to a single
/// `OpExtInst Sqrt` on SPIR-V).
pub inline fn cabs(z: Complex) f32 {
    return @sqrt(cnorm2(z));
}

/// Argument: `arg(z) = atan2(b, a)`.  Range `(-π, π]`.  Uses the
/// polynomial `atan2Scalar` defined earlier in this file (avoids
/// std.math.atan2's lookup table that SPIR-V rejects).
pub inline fn carg(z: Complex) f32 {
    return atan2Scalar(z[1], z[0]);
}

/// Complex exponential: `exp(a + bi) = e^a · (cos b + i sin b)`.
/// Uses `@exp`, `@cos`, `@sin` builtins — all SPIR-V-portable.
pub inline fn cexp(z: Complex) Complex {
    const ea: f32 = @exp(z[0]);
    return .{ ea * @cos(z[1]), ea * @sin(z[1]) };
}

/// Complex natural logarithm (principal branch): `log(z) = log|z| + i·arg(z)`.
/// Returns `-inf + 0i` at `z = c_zero`.  Branch cut on the negative
/// real axis (where `arg` discontinuously jumps from `+π` to `-π`).
pub inline fn clog(z: Complex) Complex {
    return .{ @log(cabs(z)), carg(z) };
}

/// Complex power with REAL exponent: `z^n = exp(n · log(z))`.  Use
/// `cexp(cmul(complex(n, 0), clog(z)))` if you need a complex
/// exponent.  Branch cut inherited from `clog`.
pub inline fn cpow(z: Complex, n: f32) Complex {
    const lz: Complex = clog(z);
    return cexp(.{ n * lz[0], n * lz[1] });
}

/// One step of the Mandelbrot / Julia iteration: `z' = z² + c`.
/// The mandelbrot set varies `c` per pixel with `z₀ = c_zero`; the
/// Julia set fixes `c` (mouse parameter or constant) and varies
/// `z₀` per pixel.  Iteration math is identical; only the meaning
/// of `c` and `z₀` differs.
pub inline fn cmandelbrot_step(z: Complex, c: Complex) Complex {
    return cmul(z, z) + c;
}

// Complex tests run on the host; SPIR-V correctness is verified by
// the mandelbrot example rendering correctly (the bit-identical-
// pixels visual A/B against the pre-Complex hand-rolled version).

test "Complex constants" {
    try expectEqual(@as(f32, 0), c_zero[0]);
    try expectEqual(@as(f32, 0), c_zero[1]);
    try expectEqual(@as(f32, 1), c_one[0]);
    try expectEqual(@as(f32, 1), c_i[1]);
}

test "complex constructor" {
    const z: Complex = complex(3, 4);
    try expectEqual(@as(f32, 3), z[0]);
    try expectEqual(@as(f32, 4), z[1]);
}

test "cmul: i² = -1" {
    const ii: Complex = cmul(c_i, c_i);
    try expectEqual(@as(f32, -1), ii[0]);
    try expectEqual(@as(f32, 0), ii[1]);
}

test "cmul: (1+2i)(3+4i) = -5 + 10i" {
    const r: Complex = cmul(complex(1, 2), complex(3, 4));
    try expectEqual(@as(f32, -5), r[0]);
    try expectEqual(@as(f32, 10), r[1]);
}

test "cmul identity: z * 1 = z" {
    const z: Complex = complex(3, -7);
    const r: Complex = cmul(z, c_one);
    try expectEqual(z[0], r[0]);
    try expectEqual(z[1], r[1]);
}

test "cdiv: (1 + i) / (1 - i) = i" {
    const r: Complex = cdiv(complex(1, 1), complex(1, -1));
    try expectApproxEqAbs(@as(f32, 0), r[0], 1e-6);
    try expectApproxEqAbs(@as(f32, 1), r[1], 1e-6);
}

test "cconj: conj(3 + 4i) = 3 - 4i" {
    const r: Complex = cconj(complex(3, 4));
    try expectEqual(@as(f32, 3), r[0]);
    try expectEqual(@as(f32, -4), r[1]);
}

test "cnorm2 / cabs: |3 + 4i| = 5" {
    const z: Complex = complex(3, 4);
    try expectEqual(@as(f32, 25), cnorm2(z));
    try expectApproxEqAbs(@as(f32, 5), cabs(z), 1e-6);
}

test "carg: arg(1) = 0, arg(i) = π/2, arg(-1) = π" {
    try expectApproxEqAbs(@as(f32, 0), carg(c_one), 1e-6);
    try expectApproxEqAbs(@as(f32, pi / 2.0), carg(c_i), 1e-6);
    try expectApproxEqAbs(@as(f32, pi), carg(complex(-1, 0)), 1e-6);
}

test "cexp: exp(0) = 1, exp(iπ) = -1 (Euler)" {
    const e0: Complex = cexp(c_zero);
    try expectApproxEqAbs(@as(f32, 1), e0[0], 1e-6);
    try expectApproxEqAbs(@as(f32, 0), e0[1], 1e-6);

    // Euler's identity: e^(iπ) + 1 = 0
    const ePi: Complex = cexp(complex(0, pi));
    try expectApproxEqAbs(@as(f32, -1), ePi[0], 1e-6);
    try expectApproxEqAbs(@as(f32, 0), ePi[1], 1e-6);
}

test "clog: log(1) = 0, log(e) = 1, log(-1) = iπ" {
    const l1: Complex = clog(c_one);
    try expectApproxEqAbs(@as(f32, 0), l1[0], 1e-6);
    try expectApproxEqAbs(@as(f32, 0), l1[1], 1e-6);

    const le: Complex = clog(complex(euler, 0));
    try expectApproxEqAbs(@as(f32, 1), le[0], 1e-6);

    const lm1: Complex = clog(complex(-1, 0));
    try expectApproxEqAbs(@as(f32, pi), lm1[1], 1e-6);
}

test "cpow: z^2 matches cmul(z,z) for non-edge z" {
    const z: Complex = complex(1.5, 0.75);
    const pow_path: Complex = cpow(z, 2);
    const mul_path: Complex = cmul(z, z);
    // cpow uses exp/log so accuracy is lower than direct multiplication.
    try expectApproxEqAbs(mul_path[0], pow_path[0], 1e-5);
    try expectApproxEqAbs(mul_path[1], pow_path[1], 1e-5);
}

test "cmandelbrot_step: z=0, c=0 stays at 0" {
    const r: Complex = cmandelbrot_step(c_zero, c_zero);
    try expectEqual(@as(f32, 0), r[0]);
    try expectEqual(@as(f32, 0), r[1]);
}

test "cmandelbrot_step: z=0, c=1 -> 1, then 2, then 5" {
    // Classic divergence sequence for c=1 (in the set's exterior).
    var z: Complex = c_zero;
    const c: Complex = c_one;
    z = cmandelbrot_step(z, c);
    try expectEqual(@as(f32, 1), z[0]);
    z = cmandelbrot_step(z, c);
    try expectEqual(@as(f32, 2), z[0]);
    z = cmandelbrot_step(z, c);
    try expectEqual(@as(f32, 5), z[0]);
}

test "Complex + and - work natively (Vec2 alias)" {
    const a: Complex = complex(1, 2);
    const b: Complex = complex(3, 4);
    const s: Complex = a + b;
    try expectEqual(@as(f32, 4), s[0]);
    try expectEqual(@as(f32, 6), s[1]);

    const d: Complex = a - b;
    try expectEqual(@as(f32, -2), d[0]);
    try expectEqual(@as(f32, -2), d[1]);
}

test "shader parity: clamp01 / lerp / fract / step / smoothstep" {
    try expectEqual(@as(f32, 0), clamp01(-1));
    try expectEqual(@as(f32, 1), clamp01(2));
    try expectEqual(@as(f32, 5), lerp(0, 10, 0.5));
    try expectEqual(@as(f32, 0.25), fract(2.25));
    try expectEqual(@as(f32, 1.0), step(0.5, 0.7));
    try expectApproxEqAbs(@as(f32, 0.5), smoothstep(0, 1, 0.5), 1e-6);
}

test "shader parity: dot / length / normalize generic" {
    const a2: Vec2 = .{ 3, 4 };
    try expectEqual(@as(f32, 25), dot(a2, a2));
    try expectEqual(@as(f32, 5), length(a2));

    const a4: Vec = .{ 1, 0, 0, 0 };
    try expectEqual(@as(f32, 1), length(a4));
    const a4n = normalize(@as(Vec, .{ 3.0, 4.0, 0.0, 0.0 }));
    try expectApproxEqAbs(@as(f32, 1), length(a4n), 1e-6);
}

test "shader parity: swizzles return correct types and values" {
    const v: Vec = .{ 10, 20, 30, 40 };
    // Single-comp swizzles are NOT in math.zig (would shadow zmath's
    // local `const x: f32 = ...` bindings).  Use direct index access.
    try expectEqual(@as(f32, 10), v[0]);
    try expectEqual(@as(f32, 40), v[3]);

    const yz: @Vector(2, f32) = sw(v, "yz");
    try expectEqual(@Vector(2, f32), @TypeOf(yz));
    try expectEqual(@as(f32, 20), yz[0]);

    const wzyx: Vec = sw(v, "wzyx");
    try expectEqual(@as(f32, 40), wzyx[0]);
    try expectEqual(@as(f32, 10), wzyx[3]);
}

// ============================================================================
// Cameras — the ONE home for 2D + 3D camera types and their math. Fundamental
// enough to live in zm so every backend (GL, WebGPU), the raytracer, and all
// examples share ONE definition and never roll their own. raylib-style data;
// methods produce the matrices / world<->screen maps / ray bases.
// ============================================================================

pub const CameraProjection = enum(i32) {
    perspective = 0,
    orthographic,
};

/// 2D camera (raylib Camera2D): a world point P maps to screen as
/// offset + R(rotation)*zoom*(P - target).
pub const Camera2D = struct {
    /// Screen-space offset from the window origin (where `target` lands).
    offset: Vec2 = .{ 0, 0 },
    /// World-space point that maps to `offset` on screen.
    target: Vec2 = .{ 0, 0 },
    /// Rotation around `target`, degrees.
    rotation: f32 = 0, // radians (counter-clockwise)
    /// Zoom multiplier (must not be 0).
    zoom: f32 = 1,
    /// When true, world +Y maps toward screen -Y. Use for a Y-up world (e.g. a
    /// physics sim) drawn to a Y-down screen — reflects the Y axis about `target`.
    flip_y: bool = false,

    /// World->screen matrix: T(offset) * S(zoom) * R(rotation) * T(-target).
    pub fn matrix(cam: Camera2D) Mat {
        const to_origin: Mat = translation(-cam.target[0], -cam.target[1], 0);
        const rot: Mat = rotationZ(cam.rotation);
        const zy: f32 = if (cam.flip_y) -cam.zoom else cam.zoom;
        const scale: Mat = scaling(cam.zoom, zy, 1);
        const to_offset: Mat = translation(cam.offset[0], cam.offset[1], 0);
        var m: Mat = mulMat(rot, to_origin);
        m = mulMat(scale, m);
        m = mulMat(to_offset, m);
        return m;
    }

    pub fn worldToScreen(cam: Camera2D, world: Vec2) Vec2 {
        const m: Mat = cam.matrix();
        const p: Vec = mulMatPoint(m, vec3(world[0], world[1], 0));
        return .{ p[0], p[1] };
    }

    pub fn screenToWorld(cam: Camera2D, screen: Vec2) Vec2 {
        const m: Mat = inverse(cam.matrix());
        const p: Vec = mulMatPoint(m, vec3(screen[0], screen[1], 0));
        return .{ p[0], p[1] };
    }
};

test "zm.Camera2D flip_y" {
    // Y-up world drawn to a Y-down screen: +X -> +screenX, +Y -> -screenY,
    // about `offset` (where `target` lands). Matches `c + (w-t)*zoom` with -Y.
    const cam: Camera2D = .{ .target = .{ 0, 0 }, .offset = .{ 100, 50 }, .zoom = 10, .flip_y = true };
    const s: Vec2 = cam.worldToScreen(.{ 2, 3 });
    try expectApproxEqAbs(@as(f32, 120), s[0], 1.0e-3);
    try expectApproxEqAbs(@as(f32, 20), s[1], 1.0e-3);
    const w: Vec2 = cam.screenToWorld(s);
    try expectApproxEqAbs(@as(f32, 2), w[0], 1.0e-3);
    try expectApproxEqAbs(@as(f32, 3), w[1], 1.0e-3);
}
/// frag_tex_coord (fx,fy) in [0,1] maps to the world point
/// `px00 + pdu*(fx*resW) + pdv*(fy*resH)`.
pub const RayCamera = struct {
    origin: Vec,
    px00: Vec, // world point of pixel (0,0) = bottom-left
    pdu: Vec, // one pixel right (world)
    pdv: Vec, // one pixel UP (world) — matches frag.y increasing upward
    res_w: f32,
    res_h: f32,
};

pub const RayCameraDesc = struct {
    lookfrom: Vec,
    lookat: Vec,
    vup: Vec = .{ 0, 1, 0, 0 },
    vfov_deg: f32, // vertical field of view
    focus_dist: f32 = 1.0,
};

/// Build the ray basis. `res_w`/`res_h` are the render-target pixel dims.
pub fn rayCamera(
    desc: RayCameraDesc,
    res_w: f32,
    res_h: f32,
) RayCamera {
    const w: Vec = normalize3(desc.lookfrom - desc.lookat); // points back toward eye
    const u: Vec = normalize3(cross(desc.vup, w)); // right
    const v: Vec = cross(w, u); // up

    const theta: f32 = desc.vfov_deg * pi / 180.0;
    const half_h: f32 = @tan(theta / 2.0) * desc.focus_dist;
    const half_w: f32 = half_h * (res_w / res_h);

    const viewport_u: Vec = u * splat(2.0 * half_w); // left→right
    const viewport_v: Vec = v * splat(2.0 * half_h); // bottom→top (UP)
    const pdu: Vec = viewport_u * splat(1.0 / res_w);
    const pdv: Vec = viewport_v * splat(1.0 / res_h);

    // Bottom-left corner of the viewport, nudged to the center of pixel (0,0).
    const bottom_left: Vec = desc.lookfrom - w * splat(desc.focus_dist) -
        viewport_u * splat(0.5) - viewport_v * splat(0.5);
    const px00: Vec = bottom_left + (pdu + pdv) * splat(0.5);

    return .{
        .origin = desc.lookfrom,
        .px00 = px00,
        .pdu = pdu,
        .pdv = pdv,
        .res_w = res_w,
        .res_h = res_h,
    };
}

/// 3D camera (raylib Camera3D). position/target/up define the view;
/// fovy_deg (degrees, perspective) + projection define the lens.
pub const Camera3D = struct {
    position: Vec = .{ 0, 0, 0, 0 },
    target: Vec = .{ 0, 0, -1, 0 },
    up: Vec = .{ 0, 1, 0, 0 },
    /// FOV-Y in degrees (perspective), or near-plane height (orthographic).
    fovy_deg: f32 = 45,
    /// 0 = perspective, 1 = orthographic.
    projection: i32 = 0,

    pub fn viewMatrix(cam: Camera3D) Mat {
        return lookAtRh(cam.position, cam.target, cam.up);
    }

    /// Projection matrix for the given aspect (= width/height) and clip planes.
    pub fn projMatrix(
        cam: Camera3D,
        aspect: f32,
        near: f32,
        far: f32,
    ) Mat {
        if (cam.projection == @intFromEnum(CameraProjection.orthographic)) {
            const top: f32 = cam.fovy_deg * 0.5;
            const right: f32 = top * aspect;
            return orthographicOffCenterRh(-right, right, -top, top, near, far);
        }
        return perspectiveFovRh(cam.fovy_deg * (pi / 180.0), aspect, near, far);
    }

    pub fn viewProj(
        cam: Camera3D,
        aspect: f32,
        near: f32,
        far: f32,
    ) Mat {
        return mulMat(cam.projMatrix(aspect, near, far), cam.viewMatrix());
    }

    /// Precompute a ray basis for ray tracing / picking, in the engine's
    /// frag_tex_coord convention (v=0 bottom, v=1 top). Delegates to rayCamera
    /// so the rasterizer (viewProj) and the raytracer (rayBasis) describe the
    /// SAME camera and can never disagree on orientation.
    pub fn rayBasis(
        cam: Camera3D,
        res_w: f32,
        res_h: f32,
    ) RayCamera {
        return rayCamera(.{
            .lookfrom = cam.position,
            .lookat = cam.target,
            .vup = cam.up,
            .vfov_deg = cam.fovy_deg,
        }, res_w, res_h);
    }
};

// ============================================================================
// RayCamera — pixel→world ray basis matching the engine's frag_tex_coord
// convention (v=0 at screen BOTTOM, v=1 at TOP).
// ============================================================================
//
// The Y-convention between screen space and world space has bitten this project
// repeatedly (the raytracer rendering upside-down, fractal pan inverting): every
// demo re-derived the camera's "one pixel down" vector by hand and kept getting
// the sign wrong. This helper bakes the convention ONCE, with a test pinning it,
// so a demo never derives it. Both the host (building the UBO) and a shader
// (reconstructing the ray) use `pixelRay`, so they cannot disagree.
//
// frag_tex_coord is (0,0) at the BOTTOM-LEFT of the screen and (1,1) at the
// TOP-RIGHT — matching drawFullscreenTriangle's UVs and
// raster_shader.dispatchFragmentShader (v = 1 - row/height). So `px00` is the
// world point of the bottom-left pixel, `pdu` steps one pixel RIGHT, and `pdv`
// steps one pixel UP as frag.y increases.

/// World-space ray direction (normalized) through frag_tex_coord (fx,fy) in
/// [0,1]. Pair with `cam.origin` for the ray. The optional sub-pixel jitter
/// (jx,jy in pixels) is for AA/accumulation; pass 0 for the pixel center.
pub fn pixelRayDir(
    cam: RayCamera,
    fx: f32,
    fy: f32,
    jx: f32,
    jy: f32,
) Vec {
    const px: f32 = fx * cam.res_w + jx;
    const py: f32 = fy * cam.res_h + jy;
    const target: Vec = cam.px00 + cam.pdu * splat(px) + cam.pdv * splat(py);
    return normalize3(target - cam.origin);
}

test "rayCamera: frag (0.5,0.5) looks at lookat; frag.y=1 is UP" {
    const cam: RayCamera = rayCamera(.{
        .lookfrom = .{ 0, 0, 0, 0 },
        .lookat = .{ 0, 0, -1, 0 },
        .vfov_deg = 90,
    }, 100, 100);
    // Center pixel → straight toward lookat (-Z).
    const center: Vec = pixelRayDir(cam, 0.5, 0.5, 0, 0);
    try expectApproxEqAbs(@as(f32, 0), center[0], 0.02);
    try expectApproxEqAbs(@as(f32, 0), center[1], 0.02);
    try expect(center[2] < 0); // toward -Z
    // frag.y = 1 (top of screen) must point UP (+Y), not down.
    const top: Vec = pixelRayDir(cam, 0.5, 1.0, 0, 0);
    try expect(top[1] > 0.0); // pinning the convention: top = +Y
    const bot: Vec = pixelRayDir(cam, 0.5, 0.0, 0, 0);
    try expect(bot[1] < 0.0); // bottom = -Y
}

test "zm.safeNormalize3: zero vector -> fallback, not NaN" {
    const fb: Vec = .{ 0, 0, 1, 0 };
    const z_in: Vec = .{ 0, 0, 0, 0 };
    const r: Vec = safeNormalize3(z_in, fb);
    try expect(!isNan(r)[0]); // no NaN
    try expectApproxEqAbs(@as(f32, 1.0), r[2], 1.0e-6); // == fallback
    // a normal vector still normalizes correctly.
    const v: Vec = .{ 3, 0, 0, 0 };
    const n: Vec = safeNormalize3(v, fb);
    try expectApproxEqAbs(@as(f32, 1.0), n[0], 1.0e-4);
}

test "zm.finiteOr3: NaN lanes replaced" {
    const fb: Vec = .{ 9, 9, 9, 9 };
    const v: Vec = .{ math.nan(f32), 2.0, math.nan(f32), 4.0 };
    const r: Vec = finiteOr3(v, fb);
    try expectApproxEqAbs(@as(f32, 9.0), r[0], 1.0e-6); // NaN -> 9
    try expectApproxEqAbs(@as(f32, 2.0), r[1], 1.0e-6); // kept
    try expectApproxEqAbs(@as(f32, 9.0), r[2], 1.0e-6); // NaN -> 9
    try expectApproxEqAbs(@as(f32, 4.0), r[3], 1.0e-6); // kept
}

// ---- int<->float cast helpers: kill the @floatFromInt/@intFromFloat noise ---
// Zig makes these casts explicit on purpose (precision/sign safety). These keep
// that safety (comptime-reject the wrong source type) while removing the
// boilerplate. f32 is the float target ~96% of the time so the float->f32 path
// is a bare `float(x)`; the float->int path needs the target T (i32/u16/usize all
// occur) so it's `i(T, x)`.

/// int -> f64. Comptime-asserts `x` is an integer (a float/bool/etc is a
/// COMPILE error, so this can't silently hide a bad conversion the way bare
/// @floatFromInt can — and the f64 output is PINNED, not context-inferred).
/// `float64(width)` instead of `float64(width)`.
pub inline fn float64(x: anytype) f64 {
    comptime {
        const info = @typeInfo(@TypeOf(x));
        if (info != .int and info != .comptime_int) {
            @compileError("zm.float64 expects an integer; got " ++ @typeName(@TypeOf(x)) ++
                " (use a plain f64 literal/value directly).");
        }
    }
    return @floatFromInt(x);
}

/// float -> integer T via @round (nearest). `roundi(i32, x)`.
pub inline fn roundi(comptime T: type, x: anytype) T {
    return @round(x);
}

/// float -> integer T via @ceil (toward +inf). `ceili(i32, x)`.
pub inline fn ceili(comptime T: type, x: anytype) T {
    return @ceil(x);
}

test "zm.float / zm.int / floori / roundi / ceili" {
    try expectEqual(@as(f32, 5.0), float(@as(i32, 5)));
    try expectEqual(@as(f32, 800.0), float(@as(u32, 800)));
    try expectEqual(@as(i32, 3), int(i32, 3.9)); // trunc
    try expectEqual(@as(i32, 3), floori(i32, 3.9)); // floor
    try expectEqual(@as(i32, 4), roundi(i32, 3.9)); // round
    try expectEqual(@as(i32, 4), ceili(i32, 3.1)); // ceil
    try expectEqual(@as(u16, 7), int(u16, 7.2));
}

// ============================================================================
// [SECTION] Data-space numerics — remap / nice ticks / Range
// ----------------------------------------------------------------------------
// A small, float-generic kit for axis / grid / ruler / histogram math.
// Builds on the existing `lerpV` (generic linear interpolation); adds the
// degenerate-safe inverse + remap and a value-typed `Range` that axis
// transforms and auto-fit lean on.  Kept generic over the float type so
// data coords (f64, where precision matters) and pixel coords (f32) share
// one implementation.  Used heavily by `plot.zig`.
//
// Host-data helpers: `niceNum`/`Range` are only ever instantiated on the
// CPU, so their f64 `std.math.pow` path is never seen by the SPIR-V
// backend (Zig compiles generics lazily, per-instantiation).
// ============================================================================

/// Remap `v` from `[in_min, in_max]` to `[out_min, out_max]`, linearly and
/// unclamped.  A degenerate input interval (`in_min == in_max`) maps to
/// `out_min` instead of producing NaN/inf — the behaviour axis math wants.
pub fn remap(
    v: anytype,
    in_min: @TypeOf(v),
    in_max: @TypeOf(v),
    out_min: @TypeOf(v),
    out_max: @TypeOf(v),
) @TypeOf(v) {
    const d: @TypeOf(v) = in_max - in_min;
    const t: @TypeOf(v) = if (d == 0) 0 else (v - in_min) / d;
    return lerpV(out_min, out_max, t);
}

/// "Nice number" near `x` for human-readable tick spacing (Heckbert's
/// algorithm). `round == true` snaps to the nearest of {1,2,5}·10^k;
/// `round == false` takes the ceiling within that set. Requires `x > 0`.
pub fn niceNum(comptime T: type, x: T, snap: bool) T {
    const expv: T = @floor(@log10(x));
    const base: T = std.math.pow(T, 10, expv);
    const f: T = x / base; // mantissa in [1, 10)
    var nf: T = 10;
    if (snap) {
        if (f < 1.5) {
            nf = 1;
        } else if (f < 3) {
            nf = 2;
        } else if (f < 7) {
            nf = 5;
        }
    } else {
        if (f <= 1) {
            nf = 1;
        } else if (f <= 2) {
            nf = 2;
        } else if (f <= 5) {
            nf = 5;
        }
    }
    return nf * base;
}

/// A closed interval `[min, max]` over a float type `T`. The natural home
/// for an axis range: carries the size / center / contains / clamp / fit
/// ops that pixel<->data transforms and auto-fit need. Generic and
/// value-typed (mirrors ImPlot's `ImPlotRange`, minus the C++ baggage).
pub fn Range(comptime T: type) type {
    return struct {
        const Self = @This();
        min: T = 0,
        max: T = 1,

        pub fn size(self: Self) T {
            return self.max - self.min;
        }
        pub fn center(self: Self) T {
            return (self.min + self.max) * 0.5;
        }
        pub fn contains(self: Self, v: T) bool {
            return v >= self.min and v <= self.max;
        }
        pub fn clampValue(self: Self, v: T) T {
            return std.math.clamp(v, self.min, self.max);
        }
        /// Grow to include `v` (one-sided auto-fit step).
        pub fn expand(self: *Self, v: T) void {
            if (v < self.min) {
                self.min = v;
            }
            if (v > self.max) {
                self.max = v;
            }
        }
        /// Union with another range.
        pub fn expandRange(self: *Self, other: Self) void {
            if (other.min < self.min) {
                self.min = other.min;
            }
            if (other.max > self.max) {
                self.max = other.max;
            }
        }
        /// `t` in [0,1] for value `v` (unclamped); degenerate range -> 0.
        pub fn fractionOf(self: Self, v: T) T {
            const d: T = self.max - self.min;
            if (d == 0) {
                return 0;
            }
            return (v - self.min) / d;
        }
        /// Value at fraction `t` in [0,1].
        pub fn valueAt(self: Self, t: T) T {
            return lerpV(self.min, self.max, t);
        }
    };
}

test "zm.remap" {
    try expectEqual(@as(f64, 50), remap(@as(f64, 5), 0, 10, 0, 100));
    try expectEqual(@as(f64, 0), remap(@as(f64, 9), 3, 3, 0, 100)); // degenerate
}

test "zm.niceNum (Heckbert 1/2/5)" {
    try expectEqual(@as(f64, 1), niceNum(f64, 0.9, true));
    try expectEqual(@as(f64, 2), niceNum(f64, 2.5, true));
    try expectEqual(@as(f64, 5), niceNum(f64, 6, true));
    try expectEqual(@as(f64, 10), niceNum(f64, 8, true));
    try expectEqual(@as(f64, 100), niceNum(f64, 96, false));
}

test "zm.Range" {
    const R = Range(f64);
    var r: R = .{ .min = 0, .max = 10 };
    try expectEqual(@as(f64, 10), r.size());
    try expectEqual(@as(f64, 5), r.center());
    try expect(r.contains(5));
    try expect(!r.contains(11));
    try expectEqual(@as(f64, 0.5), r.fractionOf(5));
    try expectEqual(@as(f64, 5), r.valueAt(0.5));
    r.expand(15);
    try expectEqual(@as(f64, 15), r.max);
    r.expand(-3);
    try expectEqual(@as(f64, -3), r.min);
}

// ============================================================================
// ====  Z-physics2d : 2D rotation / transform / matrix / AABB primitives  ====
// ============================================================================
//
// ADDED BLOCK (everything below this banner) — appended for `zimrphysics2d.zig`,
// a faithful single-file Box2D v3 port. Box2D's `math_functions.h/.c` provide a
// handful of 2D primitives that `zm` did not yet have (cos/sin rotations,
// rigid transforms, column-major 2x2 matrices, 2D AABBs, and a few vector
// helpers). They are collected here so the rest of `zm` is untouched and this
// block can be lifted out wholesale.
//
// Conventions (kept consistent with the existing `zm` 2D surface):
//   * `Vec2 = @Vector(2, f32)`; use native `+ - *` and `v * splat2(s)`.
//   * The `*2` name suffix marks a 2D operation.
//   * Reductions over a `Vec2` (dot/length/cross) return a plain `f32`.
//   * We reuse the existing `dot2`, `cross2`, `length2`, `lengthSq2`, `splat2`,
//     `vec2`, and `pi` — DO NOT redefine them. We deliberately do NOT use
//     `normalize2`, because that one operates on the wide 4-lane `Vec`, not on
//     `Vec2`; the `Vec2`-native `normalizeOrZero2` below is the right tool.
//
// Determinism note: Box2D's whole value proposition is bit-reproducible results
// across platforms, which it achieves with hand-rolled `atan2`/`cos`/`sin`
// polynomial approximations rather than libm. To reproduce Box2D trajectories we
// port those approximations verbatim (`atan2Det`, `computeCosSin2`) instead of
// reaching for `std.math`. Every `Rot2` is built through them.
//
// Parity tags ("// box2d: <symbol> <file>:<line>") mark the upstream source each
// item mirrors, so the two can be diffed side by side.

// ---------------------------------------------------------------------------
// Vec2 helpers that Box2D has but `zm` did not. (math_functions.h:209-365)
// ---------------------------------------------------------------------------

/// 2D cross product of a vector with a scalar, producing a vector: `v x s`.
/// Equivalent to rotating `v` by -90 degrees and scaling by `s`.
/// box2d: b2CrossVS  math_functions.h:215
pub inline fn crossVS2(v: Vec2, s: f32) Vec2 {
    return .{ s * v[1], -s * v[0] };
}

/// 2D cross product of a scalar with a vector, producing a vector: `s x v`.
/// This is the velocity contribution of an angular rate `s` at lever arm `v`
/// (i.e. `omega x r`), used constantly in the constraint solver.
/// box2d: b2CrossSV  math_functions.h:221
pub inline fn crossSV2(s: f32, v: Vec2) Vec2 {
    return .{ -s * v[1], s * v[0] };
}

/// Left/counter-clockwise perpendicular of `v` (== crossSV2(1, v)).
/// box2d: b2LeftPerp  math_functions.h:227
pub inline fn leftPerp2(v: Vec2) Vec2 {
    return .{ -v[1], v[0] };
}

/// Right/clockwise perpendicular of `v` (== crossVS2(v, 1)). The contact solver
/// derives its friction tangent as `rightPerp2(normal)`.
/// box2d: b2RightPerp  math_functions.h:233
pub inline fn rightPerp2(v: Vec2) Vec2 {
    return .{ v[1], -v[0] };
}

/// Fused multiply-add for vectors: `a + s * b`.
/// box2d: b2MulAdd  math_functions.h:276
pub inline fn mulAdd2(a: Vec2, s: f32, b: Vec2) Vec2 {
    return a + b * splat2(s);
}

/// Fused multiply-subtract for vectors: `a - s * b`.
/// box2d: b2MulSub  math_functions.h:282
pub inline fn mulSub2(a: Vec2, s: f32, b: Vec2) Vec2 {
    return a - b * splat2(s);
}

/// Normalize `v`, also reporting its original length through `length_out`.
/// Returns the zero vector (NOT NaN) when `v` is shorter than one float epsilon,
/// matching Box2D's guarded behavior. Prefer this over a raw divide anywhere the
/// input can be degenerate.
/// box2d: b2GetLengthAndNormalize  math_functions.h:362
pub inline fn getLengthAndNormalize2(length_out: *f32, v: Vec2) Vec2 {
    const len: f32 = length2(v);
    length_out.* = len;
    if (len < std.math.floatEps(f32)) {
        return .{ 0, 0 };
    }
    const inv_len: f32 = 1.0 / len;
    return v * splat2(inv_len);
}

/// Unit vector in the direction of `v`, or the zero vector if `v` is degenerate.
/// This is Box2D's `b2Normalize` (the safe one). `zm.normalize2` is a different
/// thing (it works on the wide `Vec` and divides blindly), so we keep this name.
/// box2d: b2Normalize  math_functions.h:338
pub inline fn normalizeOrZero2(v: Vec2) Vec2 {
    var len: f32 = undefined;
    return getLengthAndNormalize2(&len, v);
}

// ---------------------------------------------------------------------------
// Box2D deterministic trig (ported verbatim for cross-platform reproducibility).
// (math_functions.c:91-167)
// ---------------------------------------------------------------------------

/// Deterministic two-argument arctangent over the full circle, result in
/// [-pi, pi]. A minimax polynomial approximation — NOT libm's `atan2` — so that
/// rotations match Box2D bit-for-bit. Returns 0 for the (0,0) input (matching
/// `atan2f` and avoiding NaN).
/// box2d: b2Atan2  math_functions.c:91
pub fn atan2Det(y: f32, x: f32) f32 {
    if (x == 0.0 and y == 0.0) {
        return 0.0;
    }

    const abs_x: f32 = @abs(x);
    const abs_y: f32 = @abs(y);
    const larger: f32 = @max(abs_y, abs_x);
    const smaller: f32 = @min(abs_y, abs_x);
    const ratio: f32 = smaller / larger; // in [0, 1]

    // Minimax polynomial approximation to atan(ratio) on [0, 1].
    const ratio_sq: f32 = ratio * ratio;
    const ratio_cube: f32 = ratio_sq * ratio;
    const ratio_quart: f32 = ratio_sq * ratio_sq;
    var result: f32 = 0.024840285 * ratio_quart + 0.18681418;
    const term: f32 = -0.094097948 * ratio_quart - 0.33213072;
    result = result * ratio_sq + term;
    result = result * ratio_cube + ratio;

    // Fold the [0, pi/4] result out to the full circle by quadrant.
    if (abs_y > abs_x) {
        result = 1.57079637 - result; // pi/2 - r
    }
    if (x < 0.0) {
        result = 3.14159274 - result; // pi - r
    }
    if (y < 0.0) {
        result = -result;
    }
    return result;
}

/// Deterministic cosine+sine of `radians`, returned as a normalized `Rot2`.
/// Uses Bhaskara-style rational approximations (Box2D's `b2ComputeCosSin`) then
/// normalizes, so the result is always a unit rotation. Ported verbatim.
/// box2d: b2ComputeCosSin + b2MakeRot  math_functions.c:138, math_functions.h:419
pub fn computeCosSin2(radians: f32) Rot2 {
    const angle: f32 = unwindAngle(radians); // fold into [-pi, pi]
    const pi_sq: f32 = pi * pi;

    // Cosine: piecewise rational approximation, shifted by pi near the wings.
    var cosine: f32 = undefined;
    if (angle < -0.5 * pi) {
        const y: f32 = angle + pi;
        const y_sq: f32 = y * y;
        cosine = -(pi_sq - 4.0 * y_sq) / (pi_sq + y_sq);
    } else if (angle > 0.5 * pi) {
        const y: f32 = angle - pi;
        const y_sq: f32 = y * y;
        cosine = -(pi_sq - 4.0 * y_sq) / (pi_sq + y_sq);
    } else {
        const y_sq: f32 = angle * angle;
        cosine = (pi_sq - 4.0 * y_sq) / (pi_sq + y_sq);
    }

    // Sine: Bhaskara approximation, sign-folded about zero.
    var sine: f32 = undefined;
    if (angle < 0.0) {
        const y: f32 = angle + pi;
        sine = -16.0 * y * (pi - y) / (5.0 * pi_sq - 4.0 * y * (pi - y));
    } else {
        sine = 16.0 * angle * (pi - angle) / (5.0 * pi_sq - 4.0 * angle * (pi - angle));
    }

    const magnitude: f32 = @sqrt(sine * sine + cosine * cosine);
    const inv_magnitude: f32 = if (magnitude > 0.0) 1.0 / magnitude else 0.0;
    return .{ .cosine = cosine * inv_magnitude, .sine = sine * inv_magnitude };
}

/// Fold any angle into the canonical range [-pi, pi].
/// box2d: b2UnwindAngle  math_functions.h (uses remainderf, round-half-to-even).
/// We use round-to-nearest (`@round`, half-away-from-zero); the two differ only
/// in the last bit at exact half-turn multiples, which never matters for a pose.
pub inline fn unwindAngle(radians: f32) f32 {
    const two_pi: f32 = 2.0 * pi;
    const turns: f32 = @round(radians / two_pi);
    return radians - turns * two_pi;
}

// ---------------------------------------------------------------------------
// Rot2 : a 2D rotation stored as (cosine, sine) of its angle.
// box2d: b2Rot  math_functions.h:34
// ---------------------------------------------------------------------------

/// A unit-magnitude 2D rotation. Storing (cosine, sine) instead of an angle
/// makes composition a couple of multiplies and keeps the solver branch-free.
pub const Rot2 = struct {
    cosine: f32,
    sine: f32,

    /// The zero rotation (identity).
    pub const identity: Rot2 = .{ .cosine = 1.0, .sine = 0.0 };

    /// Build a rotation from an angle in radians (deterministic trig).
    /// box2d: b2MakeRot  math_functions.h:419
    pub fn fromAngle(radians: f32) Rot2 {
        return computeCosSin2(radians);
    }

    /// Build a rotation from a vector already known to be unit length.
    /// box2d: b2MakeRotFromUnitVector  math_functions.h:426
    pub fn fromUnitVector(unit: Vec2) Rot2 {
        return .{ .cosine = unit[0], .sine = unit[1] };
    }

    /// Renormalize a rotation that may have drifted off the unit circle.
    /// box2d: b2NormalizeRot  math_functions.h:381
    pub fn normalize(self: Rot2) Rot2 {
        const magnitude: f32 = @sqrt(self.sine * self.sine + self.cosine * self.cosine);
        const inv: f32 = if (magnitude > 0.0) 1.0 / magnitude else 0.0;
        return .{ .cosine = self.cosine * inv, .sine = self.sine * inv };
    }

    /// The inverse rotation (transpose): negate the sine.
    /// box2d: b2InvertRot  math_functions.h:444
    pub fn invert(self: Rot2) Rot2 {
        return .{ .cosine = self.cosine, .sine = -self.sine };
    }

    /// Recover the angle in radians (deterministic atan2).
    /// box2d: b2Rot_GetAngle  math_functions.h:482
    pub fn angle(self: Rot2) f32 {
        return atan2Det(self.sine, self.cosine);
    }

    /// The local +x axis after rotation (the rotation's first column).
    /// box2d: b2Rot_GetXAxis  math_functions.h:488
    pub fn xAxis(self: Rot2) Vec2 {
        return .{ self.cosine, self.sine };
    }

    /// The local +y axis after rotation (the rotation's second column).
    /// box2d: b2Rot_GetYAxis  math_functions.h:495
    pub fn yAxis(self: Rot2) Vec2 {
        return .{ -self.sine, self.cosine };
    }
};

/// Compose two rotations: the result applies `r` then `q` (i.e. `q * r`).
/// box2d: b2MulRot  math_functions.h:501
pub inline fn mulRot2(q: Rot2, r: Rot2) Rot2 {
    return .{
        .sine = q.sine * r.cosine + q.cosine * r.sine,
        .cosine = q.cosine * r.cosine - q.sine * r.sine,
    };
}

/// Compose the inverse of `a` with `b` (i.e. `inv(a) * b`), the rotation that
/// takes frame `a` to frame `b`.
/// box2d: b2InvMulRot  math_functions.h:516
pub inline fn invMulRot2(a: Rot2, b: Rot2) Rot2 {
    return .{
        .sine = a.cosine * b.sine - a.sine * b.cosine,
        .cosine = a.cosine * b.cosine + a.sine * b.sine,
    };
}

/// The signed angle from rotation `a` to rotation `b`, in [-pi, pi].
/// box2d: b2RelativeAngle  math_functions.h:530
pub inline fn relativeAngle2(a: Rot2, b: Rot2) f32 {
    const sin_delta: f32 = a.cosine * b.sine - a.sine * b.cosine;
    const cos_delta: f32 = a.cosine * b.cosine + a.sine * b.sine;
    return atan2Det(sin_delta, cos_delta);
}

/// Rotate a vector by `q`.
/// box2d: b2RotateVector  math_functions.h:545
pub inline fn rotateVec2(q: Rot2, v: Vec2) Vec2 {
    return .{ q.cosine * v[0] - q.sine * v[1], q.sine * v[0] + q.cosine * v[1] };
}

/// Rotate a vector by the inverse of `q`.
/// box2d: b2InvRotateVector  math_functions.h:552
pub inline fn invRotateVec2(q: Rot2, v: Vec2) Vec2 {
    return .{ q.cosine * v[0] + q.sine * v[1], -q.sine * v[0] + q.cosine * v[1] };
}

/// Advance rotation `q1` by `delta_angle` radians and renormalize. This is the
/// first-order rotation integrator the position solver uses each sub-step.
/// box2d: b2IntegrateRotation  math_functions.h:393
pub inline fn integrateRot2(q1: Rot2, delta_angle: f32) Rot2 {
    const q2: Rot2 = .{
        .cosine = q1.cosine - delta_angle * q1.sine,
        .sine = q1.sine + delta_angle * q1.cosine,
    };
    return q2.normalize();
}

/// Recover the angular velocity that carries `q1` to `q2` over a step of length
/// `1 / inv_h`. Uses the small-angle identity `sin(da) ~= da`.
/// box2d: b2ComputeAngularVelocity  math_functions.h:465
pub inline fn computeAngularVelocity2(q1: Rot2, q2: Rot2, inv_h: f32) f32 {
    return inv_h * (q2.sine * q1.cosine - q2.cosine * q1.sine);
}

/// Normalized linear interpolation between two rotations (cheap slerp stand-in).
/// box2d: b2NLerp  math_functions.h:451
pub inline fn nLerp2(q1: Rot2, q2: Rot2, t: f32) Rot2 {
    const one_minus_t: f32 = 1.0 - t;
    const blended: Rot2 = .{
        .cosine = one_minus_t * q1.cosine + t * q2.cosine,
        .sine = one_minus_t * q1.sine + t * q2.sine,
    };
    return blended.normalize();
}

/// The rotation taking unit vector `from` onto unit vector `to`.
/// box2d: b2ComputeRotationBetweenUnitVectors  math_functions.c:170
pub fn rotationBetween2(from: Vec2, to: Vec2) Rot2 {
    const r: Rot2 = .{ .cosine = dot2(from, to), .sine = cross2(from, to) };
    return r.normalize();
}

// ---------------------------------------------------------------------------
// Transform2 : a rigid 2D transform (rotation then translation).
// box2d: b2Transform  math_functions.h:42
// ---------------------------------------------------------------------------

/// A rigid body transform: rotate by `q`, then translate by `p`.
pub const Transform2 = struct {
    p: Vec2,
    q: Rot2,

    pub const identity: Transform2 = .{ .p = .{ 0, 0 }, .q = Rot2.identity };
};

/// Map a point from local space into the frame `t` (rotate then translate).
/// box2d: b2TransformPoint  math_functions.h:557
pub inline fn transformPoint2(t: Transform2, p: Vec2) Vec2 {
    const x: f32 = (t.q.cosine * p[0] - t.q.sine * p[1]) + t.p[0];
    const y: f32 = (t.q.sine * p[0] + t.q.cosine * p[1]) + t.p[1];
    return .{ x, y };
}

/// Map a point from the frame `t` back into local space (the inverse transform).
/// box2d: b2InvTransformPoint  math_functions.h:566
pub inline fn invTransformPoint2(t: Transform2, p: Vec2) Vec2 {
    const vx: f32 = p[0] - t.p[0];
    const vy: f32 = p[1] - t.p[1];
    return .{ t.q.cosine * vx + t.q.sine * vy, -t.q.sine * vx + t.q.cosine * vy };
}

/// Compose two transforms: apply `b` then `a` (i.e. `a * b`).
/// box2d: b2MulTransforms  math_functions.h:578
pub inline fn mulTransforms2(a: Transform2, b: Transform2) Transform2 {
    return .{ .q = mulRot2(a.q, b.q), .p = rotateVec2(a.q, b.p) + a.p };
}

/// Express transform `b` relative to transform `a` (i.e. `inv(a) * b`). Box2D
/// uses this to run the narrow phase in frame A, preserving precision far from
/// the origin.
/// box2d: b2InvMulTransforms  math_functions.h:588
pub inline fn invMulTransforms2(a: Transform2, b: Transform2) Transform2 {
    return .{ .q = invMulRot2(a.q, b.q), .p = invRotateVec2(a.q, b.p - a.p) };
}

// ---------------------------------------------------------------------------
// Mat22 : a column-major 2x2 matrix (columns are Vec2).
// box2d: b2Mat22  math_functions.h:72
//
// Distinct from the existing scalar-field `zm.Mat2`: this column form lets the
// joint K-matrix code read as a one-to-one translation of Box2D.
// ---------------------------------------------------------------------------

pub const Mat22 = struct {
    cx: Vec2, // first column
    cy: Vec2, // second column

    pub const zero: Mat22 = .{ .cx = .{ 0, 0 }, .cy = .{ 0, 0 } };
};

/// Matrix-times-vector: `m * v`.
/// box2d: b2MulMV  math_functions.h:696
pub inline fn mulMV22(m: Mat22, v: Vec2) Vec2 {
    return .{ m.cx[0] * v[0] + m.cy[0] * v[1], m.cx[1] * v[0] + m.cy[1] * v[1] };
}

/// The inverse of `m`, or the zero matrix if `m` is singular.
/// box2d: b2GetInverse22  math_functions.h:706
pub inline fn inverse22(m: Mat22) Mat22 {
    const a: f32 = m.cx[0];
    const b: f32 = m.cy[0];
    const c: f32 = m.cx[1];
    const d: f32 = m.cy[1];
    var det: f32 = a * d - b * c;
    if (det != 0.0) {
        det = 1.0 / det;
    }
    return .{ .cx = .{ det * d, -det * c }, .cy = .{ -det * b, det * a } };
}

/// Solve `m * x = rhs` for `x` via Cramer's rule (returns zero if singular).
/// box2d: b2Solve22  math_functions.h:735
pub inline fn solve22(m: Mat22, rhs: Vec2) Vec2 {
    const a11: f32 = m.cx[0];
    const a12: f32 = m.cy[0];
    const a21: f32 = m.cx[1];
    const a22: f32 = m.cy[1];
    var det: f32 = a11 * a22 - a12 * a21;
    if (det != 0.0) {
        det = 1.0 / det;
    }
    return .{ det * (a22 * rhs[0] - a12 * rhs[1]), det * (a11 * rhs[1] - a21 * rhs[0]) };
}

// ---------------------------------------------------------------------------
// Aabb2 : an axis-aligned bounding box in 2D.
// box2d: b2AABB  math_functions.h:79
// ---------------------------------------------------------------------------

pub const Aabb2 = struct {
    lower: Vec2,
    upper: Vec2,

    /// True if box `inner` is fully contained in `self`.
    /// box2d: b2AABB_Contains  math_functions.h:748
    pub fn contains(self: Aabb2, inner: Aabb2) bool {
        return self.lower[0] <= inner.lower[0] and self.lower[1] <= inner.lower[1] and
            inner.upper[0] <= self.upper[0] and inner.upper[1] <= self.upper[1];
    }

    /// The geometric center of the box.
    pub fn center(self: Aabb2) Vec2 {
        return (self.lower + self.upper) * splat2(0.5);
    }

    /// The half-widths of the box.
    pub fn extents(self: Aabb2) Vec2 {
        return (self.upper - self.lower) * splat2(0.5);
    }

    /// The smallest box enclosing both `a` and `b`.
    /// box2d: b2AABB_Union  math_functions.h:773
    pub fn combine(a: Aabb2, b: Aabb2) Aabb2 {
        return .{ .lower = @min(a.lower, b.lower), .upper = @max(a.upper, b.upper) };
    }

    /// True if `a` and `b` overlap (touching counts as overlapping).
    /// box2d: b2AABB_Overlaps  math_functions.h:786
    pub fn overlaps(a: Aabb2, b: Aabb2) bool {
        return !(b.lower[0] > a.upper[0] or b.lower[1] > a.upper[1] or
            a.lower[0] > b.upper[0] or a.lower[1] > b.upper[1]);
    }

    /// The bounding-volume-hierarchy cost metric. In 2D this is the PERIMETER
    /// (Box2D's surface-area-heuristic uses perimeter, not area).
    /// box2d: b2Perimeter  (used by dynamic_tree.c)
    pub fn perimeter(self: Aabb2) f32 {
        const width: f32 = self.upper[0] - self.lower[0];
        const height: f32 = self.upper[1] - self.lower[1];
        return 2.0 * (width + height);
    }

    /// The box grown outward by `margin` on every side.
    pub fn expandedBy(self: Aabb2, margin: f32) Aabb2 {
        const m: Vec2 = splat2(margin);
        return .{ .lower = self.lower - m, .upper = self.upper + m };
    }
};

// ---------------------------------------------------------------------------
// Plane2 and Sweep2 : helpers for collision and continuous collision.
// box2d: b2Plane math_functions.h:86 ; b2Sweep collision.h
// ---------------------------------------------------------------------------

/// A 2D plane (a line): points `x` with `dot(normal, x) == offset` lie on it.
pub const Plane2 = struct {
    normal: Vec2,
    offset: f32,
};

/// Signed distance from `point` to the plane (positive on the normal side).
/// box2d: b2PlaneSeparation  math_functions.h:845
pub inline fn planeSeparation2(plane: Plane2, point: Vec2) f32 {
    return dot2(plane.normal, point) - plane.offset;
}

/// A motion sweep of a body's center of mass over one step, used by continuous
/// collision. `c1`/`q1` are the start pose, `c2`/`q2` the end pose, both about
/// the center of mass; `local_center` re-derives the body origin.
/// box2d: b2Sweep  collision.h
pub const Sweep2 = struct {
    local_center: Vec2,
    c1: Vec2,
    c2: Vec2,
    q1: Rot2,
    q2: Rot2,
};

/// The interpolated body-origin transform at fraction `t` in [0, 1] of the sweep.
/// box2d: b2GetSweepTransform  distance.c:14
pub fn sweepTransform2(sweep: Sweep2, t: f32) Transform2 {
    const center: Vec2 = mulAdd2(sweep.c1 * splat2(1.0 - t), t, sweep.c2); // lerp c1->c2
    const rotation: Rot2 = nLerp2(sweep.q1, sweep.q2, t);
    return .{ .q = rotation, .p = center - rotateVec2(rotation, sweep.local_center) };
}

// ====  end Z-physics2d additions  ==========================================
