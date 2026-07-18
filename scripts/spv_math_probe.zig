//! scripts/spv_math_probe.zig — does a zimrmath change still lower to SPIR-V?
//!
//!   ONE SECOND. BUILDS NOTHING ELSE. Run it after ANY edit to zimrmath.zig:
//!
//!     ZIG=tools/zig-x86_64-linux-*/zig
//!     $ZIG build-obj -target spirv32-vulkan -mcpu vulkan_v1_2 \
//!       -fno-llvm -fno-lld -O ReleaseFast -ofmt=spirv \
//!       -femit-bin=/tmp/probe.spv \
//!       --dep zm -Mroot=scripts/spv_math_probe.zig -Mzm=src/zimrmath.zig
//!     .zig-cache/o/*/spv2wgsl --check /tmp/probe.spv     # transpiler parses it?
//!
//! WHY THIS EXISTS: zimrmath is compiled for BOTH the CPU and SPIR-V. A change
//! that is perfectly fine natively can fail (or silently mis-lower) on the shader
//! path — and the only way anyone had to find out was to build a whole example,
//! which after a zimrmath edit means recompiling EVERY shader. This probe
//! exercises the exact same `zig build-obj -target spirv32-vulkan` codegen the
//! real shaders take, on just zimrmath + a few calls.
//!
//! `spv2wgsl --check` matters as much as the compile: it parses the WHOLE module,
//! so it proves the transpiler understands every instruction the new code emits.
//! (The WGSL OUTPUT will be ~empty — a probe has no shader entry point, and
//! spv2wgsl only emits from one. That is expected; `--check` is the assertion.)
//!
//! Add a probe fn here whenever a math function starts being used by shaders.
//!
//! ---- the change this was written for ----
//! does the NEW generic `clamp01` lower to SPIR-V?
//!
//! The risk: `clamp01` went from `pub fn clamp01(v: f32) f32` to
//! `pub inline fn clamp01(v: anytype) @TypeOf(v)` with a `switch (@typeInfo(T))`.
//! Shaders call it 24x directly and (via `smoothstep`) many more times, so if the
//! construct did not survive Zig -> SPIR-V, every shader would break.
//!
//! Compiled with the EXACT flags the shader pipeline uses
//! (`-target spirv32-vulkan -mcpu vulkan_v1_2 -fno-llvm -fno-lld -O ReleaseFast
//! -ofmt=spirv`), so a clean object here is the same codegen path the real
//! shaders take — without building a single example.

const zm = @import("zm");

// Bound bare at file scope — the house style for zm keywords, and also exactly
// how the real shaders call them, so the probe exercises the same code shape.
const clamp01 = zm.clamp01;
const lerp = zm.lerp;
const smoothstep = zm.smoothstep;
const step = zm.step;
const Vec = zm.Vec;

// The exact call shape shaders use: scalar clamp01.
export fn probeClamp01Scalar(x: f32) f32 {
    return clamp01(x);
}

// The vector path — the branch that only exists because clamp01 absorbed
// saturate's body.
export fn probeClamp01Vec(v: Vec) Vec {
    return clamp01(v);
}

// smoothstep CALLS clamp01 internally and is used by 4 shaders — so this covers
// the indirect path too.
export fn probeSmoothstep(e0: f32, e1: f32, x: f32) f32 {
    return smoothstep(e0, e1, x);
}

// `step` is brand new (was `stepEdge`); effect_cubes_fs calls it.
export fn probeStep(edge: f32, x: f32) f32 {
    return step(edge, x);
}

// `lerp` is the canonical spelling that `mix` now redirects to.
export fn probeLerp(a: f32, b: f32, t: f32) f32 {
    return lerp(a, b, t);
}
