//! src/shaders/pbr_fs.zig — PBR fragment shader body.
//!
//! WebGPU architecture (esp. the stage-segregated binding model that
//! places the samplers in group 1 and these FS uniforms in group 2)
//! is documented centrally in src/zimr.zig — read that first.
//!
//! Standard typed-shader form (same as lambert_fs.zig): schema in
//! `pbr_fs_io.zig`; `shaderMain(io) Out` runs on SPIR-V (→ WGSL/GLSL
//! → GPU) AND wasm32 (→ CPU dispatch).  Cook-Torrance microfacet BRDF
//! with GGX/Smith/Schlick approximations, directional + point lights,
//! single-cascade shadow mapping on the first directional light,
//! Reinhard tone-map + sRGB-ish gamma, optional fog.
//!
//! Graphics-literature notation preserved as a distinct category
//! (neither WebGL nor zimr-owned): `N`, `V`, `L`, `H`, `F`, `F0`,
//! `D`, `G`, `Lo`, `NdotH`, `NdotV`, `NdotL`, `distributionGgx`,
//! `geometrySmith`, `fresnelSchlick`.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec3 = zm.Vec3;
const clamp01 = zm.clamp01;
const dot = zm.dot;
const length = zm.length;
const normalize = zm.normalize;
const pi = zm.pi;
const shader_io = @import("pbr_fs_io.zig");
const shader_externs = @import("pbr_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;
/// Single source of truth for the FS uniform block — host code (CPU
/// dispatch, side-by-side examples) constructs this directly instead
/// of maintaining a byte-mirror.
pub const Ubo = shader_io.Ubo;
/// CPU-side texture binding for the sampler accessor methods (the
/// `_texture0` etc. fields on `Io` when compiled for a non-SPIR-V
/// target).  Re-exported so consumers never import the generated
/// externs module directly.
pub const TextureRef = shader_externs.TextureRef;

// ---- Constants ------------------------------------------------------
// MUST match `pbr_common_io.MAX_*_LIGHTS` (the iface sizes the light
// arrays with those; the loop bounds need plain consts here).
const max_directional_lights: u32 = 2;
const max_point_lights: u32 = 4;

// ---- Cook-Torrance helpers ------------------------------------------
// Graphics-literature names — see module doc comment.  These take all
// inputs as parameters (no extern/io access), so they port unchanged.

// Truncate a stored vec4 uniform to the vec3 the lighting math uses.
// Pure (no extern/io access, no samples) so it ports to SPIR-V and CPU.
fn xyz3(v: Vec) Vec3 {
    return .{ v[0], v[1], v[2] };
}

fn distributionGgx(
    N: Vec3,
    H: Vec3,
    roughness: f32,
) f32 {
    const a: f32 = roughness * roughness;
    const a2: f32 = a * a;
    const NdotH: f32 = @max(dot(N, H), 0.0);
    const denom: f32 = (NdotH * NdotH * (a2 - 1.0) + 1.0);
    return a2 / @max(pi * denom * denom, 1e-7);
}

fn geometrySchlickGgx(NdotV: f32, roughness: f32) f32 {
    const r: f32 = (roughness + 1.0);
    const k: f32 = (r * r) / 8.0;
    return NdotV / (NdotV * (1.0 - k) + k);
}

fn geometrySmith(
    N: Vec3,
    V: Vec3,
    L: Vec3,
    roughness: f32,
) f32 {
    const NdotV: f32 = @max(dot(N, V), 0.0);
    const NdotL: f32 = @max(dot(N, L), 0.0);
    return geometrySchlickGgx(NdotV, roughness) * geometrySchlickGgx(NdotL, roughness);
}

fn fresnelSchlick(cos_theta: f32, F0: Vec3) Vec3 {
    const one: Vec3 = .{ 1.0, 1.0, 1.0 };
    const t: f32 = blk: {
        const c: f32 = clamp01(1.0 - cos_theta);
        const c2: f32 = c * c;
        break :blk c2 * c2 * c;
    };
    return F0 + (one - F0) * @as(Vec3, @splat(t));
}

fn brdf(
    N: Vec3,
    V: Vec3,
    L: Vec3,
    radiance: Vec3,
    albedo: Vec3,
    metallic: f32,
    roughness: f32,
    F0: Vec3,
) Vec3 {
    const H: Vec3 = normalize(V + L);
    const NdotL: f32 = @max(dot(N, L), 0.0);
    const NdotV: f32 = @max(dot(N, V), 0.0);

    const D: f32 = distributionGgx(N, H, roughness);
    const G: f32 = geometrySmith(N, V, L, roughness);
    const F: Vec3 = fresnelSchlick(@max(dot(H, V), 0.0), F0);

    const specular: Vec3 =
        F * @as(Vec3, @splat((D * G) / @max(4.0 * NdotV * NdotL, 1e-7)));

    const kS: Vec3 = F;
    const one: Vec3 = .{ 1.0, 1.0, 1.0 };
    const kD: Vec3 = (one - kS) * @as(Vec3, @splat(1.0 - metallic));

    const diffuse_term: Vec3 = kD * albedo * @as(Vec3, @splat(1.0 / pi));
    return (diffuse_term + specular) * radiance * @as(Vec3, @splat(NdotL));
}

/// Light-space position → shadow-map texture coords ([0,1]).  Pure math
/// (no sampling, no branches) so the shadow-map sample it feeds can be
/// taken at the shader's uniform top.
fn shadowProjCoords(io_in: Io) Vec3 {
    const inv_w: f32 = 1.0 / io_in.frag_light_space_pos[3];
    var proj_coords: Vec3 = .{
        io_in.frag_light_space_pos[0] * inv_w,
        io_in.frag_light_space_pos[1] * inv_w,
        io_in.frag_light_space_pos[2] * inv_w,
    };
    proj_coords = proj_coords * @as(Vec3, @splat(0.5)) + @as(Vec3, @splat(0.5));
    return proj_coords;
}

/// 1.0 if fully lit, 0.0 if fully shadowed.  Slope-scaled bias
/// suppresses acne on grazing surfaces; constant floor catches the
/// flat-surface case where (1 - N·L) is zero.  Takes the light-space
/// `proj_coords` and the already-sampled `closest_depth` (sampled at the
/// uniform top of `shaderMain`) — this function does NO texture sampling,
/// so it is safe to call from the per-light branch.
fn computeShadow(
    io_in: Io,
    N: Vec3,
    L: Vec3,
    proj_coords: Vec3,
    closest_depth: f32,
) f32 {
    if (io_in.u.shadow_enabled == 0) {
        return 1.0;
    }

    // Outside the shadow frustum: treat as fully lit (no hard edge).
    if (proj_coords[0] < 0.0 or proj_coords[0] > 1.0 or
        proj_coords[1] < 0.0 or proj_coords[1] > 1.0 or
        proj_coords[2] > 1.0)
    {
        return 1.0;
    }

    const current_depth: f32 = proj_coords[2];
    const bias: f32 = @max(0.005 * (1.0 - dot(N, L)), 0.0005);

    return if ((current_depth - bias) > closest_depth) 0.0 else 1.0;
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    // ---- Base color from baseColorTexture * baseColorFactor ---------
    const tex_rgba: Vec = io_in.texture0(io_in.frag_tex_coord);
    const tex_rgb: Vec3 = .{ tex_rgba[0], tex_rgba[1], tex_rgba[2] };
    const col_diffuse_rgb: Vec3 = .{
        io_in.u.col_diffuse[0],
        io_in.u.col_diffuse[1],
        io_in.u.col_diffuse[2],
    };
    const albedo: Vec3 = tex_rgb * col_diffuse_rgb;

    // ---- Metallic + roughness from MR texture * scalar factors ------
    // glTF packs both in one texture: B = metallic, G = roughness.
    const mr_sample: Vec = io_in.metallic_roughness(io_in.frag_tex_coord);
    const metallic: f32 = mr_sample[2] * io_in.u.metallic_factor;
    // Roughness floor of 0.05 — pure-mirror GGX is numerically unstable.
    const roughness: f32 = @max(mr_sample[1] * io_in.u.roughness_factor, 0.05);

    // ---- Uniform vec3s are stored as vec4 in the Ubo (std140 wants
    //      16-byte field alignment); pull out the xyz the math uses. ----
    const view_pos: Vec3 = xyz3(io_in.u.view_pos);
    const ambient_color: Vec3 = xyz3(io_in.u.ambient_color);
    const emissive_factor: Vec3 = xyz3(io_in.u.emissive_factor);
    const fog_color: Vec3 = xyz3(io_in.u.fog_color);

    // ---- Normal: TBN-rotate the tangent-space sample to world space -
    const N_geom: Vec3 = normalize(io_in.frag_world_normal);
    const T: Vec3 = normalize(Vec3{
        io_in.frag_world_tangent[0],
        io_in.frag_world_tangent[1],
        io_in.frag_world_tangent[2],
    });
    const handedness: f32 = io_in.frag_world_tangent[3];
    const B: Vec3 = Vec3{
        (N_geom[1] * T[2] - N_geom[2] * T[1]) * handedness,
        (N_geom[2] * T[0] - N_geom[0] * T[2]) * handedness,
        (N_geom[0] * T[1] - N_geom[1] * T[0]) * handedness,
    };
    const n_sample: Vec = io_in.normal(io_in.frag_tex_coord);
    const n_unpacked: Vec3 = .{
        n_sample[0] * 2.0 - 1.0,
        n_sample[1] * 2.0 - 1.0,
        n_sample[2] * 2.0 - 1.0,
    };
    // N_world = TBN * n_unpacked   (column-major: T*x + B*y + N_geom*z)
    const N: Vec3 = normalize(Vec3{
        T[0] * n_unpacked[0] + B[0] * n_unpacked[1] + N_geom[0] * n_unpacked[2],
        T[1] * n_unpacked[0] + B[1] * n_unpacked[1] + N_geom[1] * n_unpacked[2],
        T[2] * n_unpacked[0] + B[2] * n_unpacked[1] + N_geom[2] * n_unpacked[2],
    });

    const V: Vec3 = normalize(view_pos - io_in.frag_world_pos);

    // ---- ALL remaining texture samples, taken HERE at the shader's
    // uniform top.  WGSL forbids a sampler call in non-uniform control
    // flow, so every sample must be unconditional and outside any
    // branch/loop.  Base color, metallic-roughness, and normal were
    // sampled above; occlusion, emissive, and the shadow map are sampled
    // now, and their values threaded into the lighting/shadow math below
    // (computeShadow no longer samples).  Sampling an unused map / when
    // shadows are off is harmless — the value is simply discarded.  This
    // discipline is enforced by the `sampler-at-top` lint.
    const ao_sample: Vec = io_in.occlusion(io_in.frag_tex_coord);
    const e_sample: Vec = io_in.emissive(io_in.frag_tex_coord);
    const shadow_proj: Vec3 = shadowProjCoords(io_in);
    const shadow_closest: f32 = io_in.shadow_map(.{ shadow_proj[0], shadow_proj[1] })[0];

    // ---- F0: dielectric base for non-metals, albedo tint for metals -
    const dielectric: Vec3 = .{ 0.04, 0.04, 0.04 };
    const F0: Vec3 =
        dielectric * @as(Vec3, @splat(1.0 - metallic)) + albedo * @as(Vec3, @splat(metallic));

    // ---- Light accumulation -----------------------------------------
    var Lo: Vec3 = .{ 0.0, 0.0, 0.0 };

    // Directional lights.  Only the FIRST casts shadows in v1.
    // Light arrays are vec4-padded for std140; take .xyz (.w unused).
    var i: i32 = 0;
    while (i < io_in.u.directional_light_count and i < @as(i32, max_directional_lights)) : (i += 1) {
        const idx: usize = @intCast(i);
        const L_neg: @Vector(4, f32) = io_in.u.directional_light_dir[idx];
        const L: Vec3 = normalize(Vec3{ -L_neg[0], -L_neg[1], -L_neg[2] });
        const shadow: f32 = if (i == 0) computeShadow(io_in, N, L, shadow_proj, shadow_closest) else 1.0;
        const lc: @Vector(4, f32) = io_in.u.directional_light_color[idx];
        const radiance: Vec3 = Vec3{ lc[0], lc[1], lc[2] } * @as(Vec3, @splat(shadow));
        Lo = Lo + brdf(N, V, L, radiance, albedo, metallic, roughness, F0);
    }

    // Point lights.  Linear-falloff approximation (squared for softness).
    var j: i32 = 0;
    while (j < io_in.u.point_light_count and j < @as(i32, max_point_lights)) : (j += 1) {
        const idx: usize = @intCast(j);
        const pp: @Vector(4, f32) = io_in.u.point_light_pos[idx];
        const to_light: Vec3 = Vec3{ pp[0], pp[1], pp[2] } - io_in.frag_world_pos;
        const dist: f32 = length(to_light);
        const range: f32 = io_in.u.point_light_range[idx][0];
        if (dist > range) {
            continue;
        }
        const L: Vec3 = to_light * @as(Vec3, @splat(1.0 / @max(dist, 1e-7)));
        const falloff: f32 = @min(@max(1.0 - dist / range, 0.0), 1.0);
        const pc: @Vector(4, f32) = io_in.u.point_light_color[idx];
        const radiance: Vec3 =
            Vec3{ pc[0], pc[1], pc[2] } * @as(Vec3, @splat(falloff * falloff));
        Lo = Lo + brdf(N, V, L, radiance, albedo, metallic, roughness, F0);
    }

    // ---- Ambient with occlusion (R channel; ambient term only) ------
    const ao: f32 = ao_sample[0];
    const ambient: Vec3 = ambient_color * albedo * @as(Vec3, @splat(ao));

    // ---- Emissive (additive, before tone-map) -----------------------
    const emissive: Vec3 = Vec3{ e_sample[0], e_sample[1], e_sample[2] } * emissive_factor;

    var color: Vec3 = ambient + Lo + emissive;

    // ---- Reinhard tone-map + sRGB-ish gamma -------------------------
    const one: Vec3 = .{ 1.0, 1.0, 1.0 };
    color = color / (color + one);
    color = .{
        @exp(@log(color[0]) * (1.0 / 2.2)),
        @exp(@log(color[1]) * (1.0 / 2.2)),
        @exp(@log(color[2]) * (1.0 / 2.2)),
    };

    if (io_in.u.fog_enabled == 1) {
        const dist: f32 = length(view_pos - io_in.frag_world_pos);
        const fog_range: f32 = @max(io_in.u.fog_far - io_in.u.fog_near, 1e-7);
        const fog_amount: f32 = clamp01((dist - io_in.u.fog_near) / fog_range);
        color = color * @as(Vec3, @splat(1.0 - fog_amount)) +
            fog_color * @as(Vec3, @splat(fog_amount));
    }

    out.out_color = Vec{ color[0], color[1], color[2], io_in.u.col_diffuse[3] };
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
