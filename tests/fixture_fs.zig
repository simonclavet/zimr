//! tests/fixture_fs.zig - minimal smoke shader for the shader build path.
//! `zig build check` compiles it to SPIR-V and translates it, so it proves the
//! zimrmath helpers a shader leans on still lower on the SPIR-V backend:
//!
//!   - Vec2/Vec3/Vec types
//!   - vec2/vec3/vec4 builders
//!   - sw swizzle helper
//!   - dot/length/normalize generic vector helpers
//!   - clamp01/lerp/fract/smoothstep scalar helpers
//!
//! Hand-written rather than schema-generated, so it also shows the raw shape
//! every generated shader has: each interface variable is a file-scope
//! `@extern` carrying its own decoration. (Decorating through inline asm from
//! inside `main` - the old `sb.location(&x, 0)` - is silently dropped by Zig's
//! SPIR-V linker since 0.17.0-dev.2307.)

const zm = @import("zm");

// Stage input / output: the location rides on the declaration.
const frag_tex_coord = @extern(*addrspace(.input) const Vec2, .{
    .name = "frag_tex_coord",
    .decoration = .{ .location = 0 },
});
const out_color = @extern(*addrspace(.output) Vec, .{
    .name = "out_color",
    .decoration = .{ .location = 0 },
});

// Uniforms: one block at the fragment-stage uniform group (2), binding 0. The
// compiler requires a `.uniform` extern to point at a struct.
const Uniforms = extern struct {
    tint: Vec,
    resolution: Vec2,
    time: f32,
};
const u = @extern(*addrspace(.uniform) const Uniforms, .{
    .name = "u",
    .decoration = .{ .descriptor = .{ .set = 2, .binding = 0 } },
});

// The zimrmath vocabulary this fixture exercises, bound once so the body reads
// like shader code rather than a list of `zm.` calls.
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const Vec3 = zm.Vec3;
const vec2 = zm.vec2;
const vec3 = zm.vec3;
const vec4 = zm.vec4;
const dot = zm.dot;
const length = zm.length;
const normalize = zm.normalize;
const smoothstep = zm.smoothstep;
const fract = zm.fract;
const lerp = zm.lerp;
const clamp01 = zm.clamp01;

/// Helper function - proves `pub fn` (NOT `pub inline fn`) is the
/// right shape (forcing inline at the Zig level breaks the SPIR-V
/// structured-control-flow markers).
fn brightness(c: Vec3) f32 {
    return dot(c, vec3(0.299, 0.587, 0.114));
}

export fn main() callconv(.{ .spirv_fragment = .{} }) void {
    // Swizzles + Vec2/Vec3 math: centre the UV and correct for aspect.
    const uv: Vec2 = frag_tex_coord.*;
    const aspect: f32 = u.resolution[0] / u.resolution[1];
    const centered: Vec2 = vec2((uv[0] - 0.5) * aspect, uv[1] - 0.5);

    // length + smoothstep: a soft ring around the centre.
    const distance_from_center: f32 = length(centered);
    const ring: f32 = smoothstep(0.4, 0.45, distance_from_center) * smoothstep(0.5, 0.45, distance_from_center);

    // lerp + fract + a Vec3 build: a colour cycling between two endpoints.
    const cycle: f32 = fract(u.time * 0.25);
    const color_a: Vec3 = vec3(1.0, 0.0, 0.5);
    const color_b: Vec3 = vec3(0.0, 0.8, 1.0);
    const base: Vec3 = vec3(
        lerp(color_a[0], color_b[0], cycle),
        lerp(color_a[1], color_b[1], cycle),
        lerp(color_a[2], color_b[2], cycle),
    );

    // Helper fn + normalize + sw + clamp01: the ring takes the tint's hue at the
    // base colour's brightness.
    const luminance: f32 = clamp01(brightness(base));
    const tint_rgb: Vec3 = zm.sw(u.tint, "xyz");
    const tint_direction: Vec3 = normalize(tint_rgb);
    const tinted: Vec3 = vec3(
        tint_direction[0] * luminance,
        tint_direction[1] * luminance,
        tint_direction[2] * luminance,
    );

    const final_color: Vec = vec4(
        base[0] * (1.0 - ring) + tinted[0] * ring,
        base[1] * (1.0 - ring) + tinted[1] * ring,
        base[2] * (1.0 - ring) + tinted[2] * ring,
        1.0,
    );
    out_color.* = final_color;
}
