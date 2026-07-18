//! tests/fixture.fs.zig — minimal smoke shader for the addShader
//! build helper.  Exercises the four-stage pipeline (zig build-obj
//! → spirv-opt → spirv-val → spirv-cross) on a shader that uses
//! every shadermath feature we ship in S1.2:
//!
//!   - Vec2/Vec3/Vec types
//!   - vec2/vec3/vec4 builders
//!   - sw swizzle helper
//!   - dot/length/normalize generic vector helpers
//!   - clamp01/mix/fract/smoothstep scalar helpers
//!   - `location` decorator (runtime SPIR-V asm form)
//!
//! Not used at runtime; the build step compiles it to verify the
//! pipeline produces valid GLSL ES 3.0.  See `tests/fixture_test.zig`
//! for the actual assertion that the compiled .glsl contains
//! `#version 300 es`.

const zm = @import("zm");
const sb = @import("shader_builtins");

// Stage inputs
extern const frag_tex_coord: zm.Vec2 addrspace(.input);

// Stage outputs
extern var out_color: zm.Vec addrspace(.output);

// Uniforms (individual extern style — pre-UBO; the fixture validates
// the build pipeline can still compile this shape even though
// production shaders use UBO blocks instead).
extern const u_time: f32 addrspace(.uniform);
extern const u_resolution: zm.Vec2 addrspace(.uniform);
extern const u_tint: zm.Vec addrspace(.uniform);

/// Helper function — proves `pub fn` (NOT `pub inline fn`) is the
/// right shape (forcing inline at the Zig level breaks the SPIR-V
/// structured-control-flow markers).
fn brightness(c: zm.Vec3) f32 {
    return zm.dot(c, zm.vec3(0.299, 0.587, 0.114));
}

export fn main() callconv(.{ .spirv_fragment = .{} }) void {
    sb.location(&out_color, 0);

    // Test swizzles + Vec2/Vec3 math
    const uv = frag_tex_coord;
    const aspect = u_resolution[0] / u_resolution[1];
    const centered = zm.vec2((uv[0] - 0.5) * aspect, uv[1] - 0.5);

    // Test length + smoothstep
    const dist = zm.length(centered);
    const ring = zm.smoothstep(0.4, 0.45, dist) * zm.smoothstep(0.5, 0.45, dist);

    // Test mix + fract + a Vec3 build
    const t = zm.fract(u_time * 0.25);
    const a = zm.vec3(1.0, 0.0, 0.5);
    const b = zm.vec3(0.0, 0.8, 1.0);
    const base = zm.vec3(
        zm.lerp(a[0], b[0], t),
        zm.lerp(a[1], b[1], t),
        zm.lerp(a[2], b[2], t),
    );

    // Test helper fn + normalize + sw + clamp01
    const lum = zm.clamp01(brightness(base));
    const tint_rgb = zm.sw(u_tint, "xyz");
    const tint_n = zm.normalize(tint_rgb);
    const tinted = zm.vec3(
        tint_n[0] * lum,
        tint_n[1] * lum,
        tint_n[2] * lum,
    );

    out_color = zm.vec4(
        base[0] * (1.0 - ring) + tinted[0] * ring,
        base[1] * (1.0 - ring) + tinted[1] * ring,
        base[2] * (1.0 - ring) + tinted[2] * ring,
        1.0,
    );
}
