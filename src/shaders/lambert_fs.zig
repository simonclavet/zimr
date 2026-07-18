//! src/shaders/lambert_fs.zig — Lambert fragment shader body.
//!
//! Lambertian diffuse + ambient with a single fixed directional light
//! in world space.  Sample albedo from `texture0`, modulate by
//! `lighting * col_diffuse`.  25% ambient floor preserves back-face
//! visibility during rotation.  Hard-coded light direction
//! (`normalize(vec3(0.4, 0.8, 0.5))`) — same convention as the prior
//! GLSL version.
//!
//! Schema (Inputs / Samplers / Uniforms / Outputs) lives in
//! `lambert_fs_io.zig`.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec3 = zm.Vec3;
const dot = zm.dot;
const normalize = zm.normalize;
const shader_io = @import("lambert_fs_io.zig");
const shader_externs = @import("lambert_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Uniforms);
pub const Out = shader_externs.Out;
pub const TextureRef = shader_externs.TextureRef;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const light_dir: Vec3 = normalize(Vec3{ 0.4, 0.8, 0.5 });
    const nrm: Vec3 = normalize(io_in.frag_normal);
    const n_dot_l: f32 = @max(dot(nrm, light_dir), 0.0);

    const ambient: f32 = 0.25;
    const lighting: f32 = ambient + (1.0 - ambient) * n_dot_l;

    const tex: Vec = io_in.texture0(io_in.frag_tex_coord);
    const lit: Vec = .{
        tex[0] * lighting,
        tex[1] * lighting,
        tex[2] * lighting,
        tex[3],
    };
    out.final_color = lit * io_in.col_diffuse;

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
