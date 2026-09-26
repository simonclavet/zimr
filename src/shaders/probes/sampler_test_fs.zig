//! src/shaders/probes/sampler_test_fs.zig - S1.4.5b end-to-end probe.
//!
//! Validates the full sampler-shader pipeline:
//!   Zig source ->
//!   `zig build-obj -target spirv32-vulkan` ->
//!   limited-pass-list spirv-opt (NOT `-O`) ->
//!   spirv-val ->
//!   spirv-cross --version 300 --es ->
//!   `rewriteSamplers` (in shader_post.zig) ->
//!   final GLSL ready for `loadShaderFromMemory`.
//!
//! Mirrors the 5-sampler probe from the derisk session
//! (`src/notes/s1.4.5b-sampler-derisk.md`).  Use as a regression
//! base: any change to the build pipeline, shadermath helpers, or
//! `rewriteSamplers` should keep this shader producing output
//! shaped like `examples/shared/shaders/_sampler_derisk.fs.glsl`.
//!
//! NOT registered for general use - purely a build-pipeline probe.
//! `examples/sampler_derisk_test.zig` loads the post-processed GLSL
//! via `loadShaderFromMemory` to confirm WebGL2 acceptance.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const sb = @import("shader_builtins");
const zsample2d = sb.zsample2d;

// ---- Stage inputs (varying from VS) ---------------------------------
extern const frag_uv: Vec2 addrspace(.input);

// ---- Stage outputs --------------------------------------------------
extern var color: Vec addrspace(.output);

// ---- Samplers (S1.4.5b convention) ----------------------------------
// Declared as `u32 addrspace(.constant)` placeholders.  Zig emits
// `uniform uint NAME_sampler2d;` in the GLSL output; `rewriteSamplers`
// rewrites them to `uniform sampler2D NAME;` based on the names
// passed at the @embedFile site (see `shader_post.zig`).
extern const s_albedo_sampler2d: u32 addrspace(.constant);
extern const s_normal_sampler2d: u32 addrspace(.constant);
extern const s_metallic_sampler2d: u32 addrspace(.constant);
extern const s_emissive_sampler2d: u32 addrspace(.constant);
extern const s_ao_sampler2d: u32 addrspace(.constant);

export fn main() callconv(.{ .spirv_fragment = .{} }) void {
    // All 5 sample calls combined into the output so none get
    // dead-stripped.  Each call site goes through the same
    // `__sample2d` helper (from shadermath); spirv-cross emits
    // exactly one function definition, N call sites.
    const a: Vec = zsample2d(s_albedo_sampler2d, frag_uv);
    const n: Vec = zsample2d(s_normal_sampler2d, frag_uv);
    const m: Vec = zsample2d(s_metallic_sampler2d, frag_uv);
    const e: Vec = zsample2d(s_emissive_sampler2d, frag_uv);
    const ao: Vec = zsample2d(s_ao_sampler2d, frag_uv);

    color = Vec{
        a[0] * ao[0] + e[0],
        a[1] * n[0] * m[0] + e[1],
        a[2] * n[1] * m[1] + e[2],
        a[3],
    };
}
