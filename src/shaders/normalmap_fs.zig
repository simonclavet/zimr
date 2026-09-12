//! src/shaders/normalmap_fs.zig — the "what is a normal map" fragment shader.
//!
//! Port of raylib's examples/shaders/resources/shaders/glsl330/normalmap.fs.
//! Deliberately NOT full PBR (that's `pbr_fs` / `pbr_demo`): this is the plain,
//! legible version so a reader can see the whole technique at once —
//!   1. sample the tangent-space normal from the normal map,
//!   2. rotate it into world space with the TBN frame the vertex shader built,
//!   3. light it with one directional light: Lambert diffuse + Blinn-Phong
//!      specular, plus a flat ambient term.
//! When the bound normal map is flat (128,128,255) the sampled normal is
//! (0,0,1) and N collapses to the geometric normal — i.e. the "normal map off"
//! comparison is just a different (flat) texture, no shader branch needed.
//!
//! Reuses `pbr_fs_io` so it shares the pbr3d bind-group layout (see that file).
const zm = @import("zm");
const Vec = zm.Vec;
const Vec3 = zm.Vec3;
const dot = zm.dot;
const normalize = zm.normalize;
const shader_io = @import("normalmap_fs_io.zig");
const shader_externs = @import("normalmap_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;
pub const Ubo = shader_io.Ubo;
pub const TextureRef = shader_externs.TextureRef;

const max_directional_lights: u32 = 2;

fn xyz3(v: Vec) Vec3 {
    return .{ v[0], v[1], v[2] };
}

pub fn shaderMain(io_in: Io) Out {
    // 1. Albedo from the diffuse (tile) texture, tinted by col_diffuse.
    const tex_rgba: Vec = io_in.texture0(io_in.frag_tex_coord);
    const tint: Vec3 = xyz3(io_in.u.col_diffuse);
    const albedo: Vec3 = Vec3{ tex_rgba[0], tex_rgba[1], tex_rgba[2] } * tint;

    // 2. Build the TBN frame from the interpolated world normal + tangent, then
    //    rotate the sampled tangent-space normal into world space. A flat normal
    //    map sample (0,0,1) leaves N == geometric normal.
    const n_geom: Vec3 = normalize(io_in.frag_world_normal);
    const t_raw: Vec3 = .{
        io_in.frag_world_tangent[0],
        io_in.frag_world_tangent[1],
        io_in.frag_world_tangent[2],
    };
    const t: Vec3 = normalize(t_raw);
    const handed: f32 = io_in.frag_world_tangent[3];
    const bitangent: Vec3 = Vec3{
        n_geom[1] * t[2] - n_geom[2] * t[1],
        n_geom[2] * t[0] - n_geom[0] * t[2],
        n_geom[0] * t[1] - n_geom[1] * t[0],
    } * @as(Vec3, @splat(handed));
    const n_sample: Vec = io_in.normal(io_in.frag_tex_coord);
    const n_ts: Vec3 = Vec3{ n_sample[0], n_sample[1], n_sample[2] } *
        @as(Vec3, @splat(2.0)) - @as(Vec3, @splat(1.0));
    const world_n: Vec3 = normalize(
        t * @as(Vec3, @splat(n_ts[0])) +
            bitangent * @as(Vec3, @splat(n_ts[1])) +
            n_geom * @as(Vec3, @splat(n_ts[2])),
    );

    // 3. Lighting. View vector for the Blinn-Phong half-vector.
    const view_pos: Vec3 = xyz3(io_in.u.view_pos);
    const view_dir: Vec3 = normalize(view_pos - io_in.frag_world_pos);
    var color: Vec3 = albedo * xyz3(io_in.u.ambient_color);

    var i: i32 = 0;
    while (i < io_in.u.directional_light_count and i < @as(i32, max_directional_lights)) : (i += 1) {
        const idx: u32 = @intCast(i);
        const dir4: Vec = io_in.u.directional_light_dir[idx];
        // Uniform stores the direction the light travels; the vector TO the
        // light is its negation.
        const light_dir: Vec3 = normalize(Vec3{ -dir4[0], -dir4[1], -dir4[2] });
        const lcol: Vec3 = xyz3(io_in.u.directional_light_color[idx]);

        const n_dot_l: f32 = @max(dot(world_n, light_dir), 0.0);
        const half_dir: Vec3 = normalize(light_dir + view_dir);
        const n_dot_h: f32 = @max(dot(world_n, half_dir), 0.0);
        // Blinn-Phong specular exponent 16 via repeated squaring (no pow
        // builtin), gated by n_dot_l so back-faces get no highlight.
        const s2: f32 = n_dot_h * n_dot_h;
        const s4: f32 = s2 * s2;
        const s8: f32 = s4 * s4;
        const spec: f32 = s8 * s8 * n_dot_l;

        const diffuse: Vec3 = albedo * lcol * @as(Vec3, @splat(n_dot_l));
        const specular: Vec3 = lcol * @as(Vec3, @splat(spec * 0.5));
        color = color + diffuse + specular;
    }

    return Out{ .out_color = Vec{ color[0], color[1], color[2], tex_rgba[3] } };
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
