//! src/shaders/fog_fs.zig — distance-fog fragment shader.
//!
//! Forward Blinn-ish lighting (Lambert diffuse + a modest specular),
//! then the whole result is folded toward `fog_color` by raylib's
//! exponential-squared falloff: `visibility = 1/e^((d·density)²)`.
//! The squared exponent is the trick — near geometry stays almost
//! untouched (the curve is flat at 0), then visibility collapses fast
//! past the knee, which reads as a wall of atmosphere instead of a
//! linear grey wash.
//!
//! The VERTEX stage is `gbuffer_vs`, reused as-is — this FS consumes
//! the same world-position + world-normal varyings the G-buffer pair
//! shares (`gbuffer_common_io.Interp`).  Schema in `fog_fs_io.zig`.

const zm = @import("zm");
const Vec3 = zm.Vec3;
const clamp01 = zm.clamp01;
const dot = zm.dot;
const normalize = zm.normalize;
const shader_io = @import("fog_fs_io.zig");
const shader_externs = @import("fog_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

/// Ambient floor so fully back-lit faces still read as shape.
const ambient_strength: f32 = 0.18;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const normal: Vec3 = normalize(io_in.frag_world_normal);
    const light_dir: Vec3 = normalize(Vec3{
        io_in.u.light_dir[0],
        io_in.u.light_dir[1],
        io_in.u.light_dir[2],
    });
    const to_eye: Vec3 = .{
        io_in.u.view_pos[0] - io_in.frag_world_pos[0],
        io_in.u.view_pos[1] - io_in.frag_world_pos[1],
        io_in.u.view_pos[2] - io_in.frag_world_pos[2],
    };
    const view_dir: Vec3 = normalize(to_eye);

    // Lambert + Blinn specular (pow 16 as four squarings — raylib's
    // "Shine: 16.0", minus the transcendental).
    const n_dot_l: f32 = @max(dot(normal, light_dir), 0.0);
    const half_dir: Vec3 = normalize(light_dir + view_dir);
    const n_dot_h: f32 = @max(dot(normal, half_dir), 0.0);
    const spec: f32 = pow16(n_dot_h) * 0.55;

    const lighting: f32 = ambient_strength + (1.0 - ambient_strength) * n_dot_l;
    const lit: Vec3 = Vec3{
        io_in.u.base_color[0],
        io_in.u.base_color[1],
        io_in.u.base_color[2],
    } * @as(Vec3, @splat(lighting)) + @as(Vec3, @splat(spec * n_dot_l));

    // The fog: distance from the CAMERA (not depth — fog is radial, so
    // spinning in place doesn't make the corners of the screen clear up).
    const dist: f32 = @sqrt(@max(dot(to_eye, to_eye), 1.0e-8));
    const dd: f32 = dist * io_in.u.params[0];
    const visibility: f32 = clamp01(1.0 / @exp(dd * dd));

    const fog: Vec3 = .{ io_in.u.fog_color[0], io_in.u.fog_color[1], io_in.u.fog_color[2] };
    const final: Vec3 = fog + (lit - fog) * @as(Vec3, @splat(visibility));

    out.final_color = .{ final[0], final[1], final[2], 1.0 };
    return out;
}

/// x^16 as four squarings.
fn pow16(x: f32) f32 {
    const x2: f32 = x * x;
    const x4: f32 = x2 * x2;
    const x8: f32 = x4 * x4;
    return x8 * x8;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
