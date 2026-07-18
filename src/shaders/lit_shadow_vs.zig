//! src/shaders/lit_shadow_vs.zig — shadow-mapped Lambert vertex shader.
//!
//! Projects the world-space vertex through the camera MVP for the main
//! pass, carries the world-space normal for diffuse lighting, and also
//! projects through the LIGHT's view-projection so the FS receives the
//! fragment's position in light-clip space (→ shadow-map lookup).

const zm = @import("zm");
const Vec = zm.Vec;
const Vec3 = zm.Vec3;
const mulMatPoint = zm.mulMatPoint;
const mulMatVec = zm.mulMatVec;
const normalize = zm.normalize;
const vec4 = zm.vec4;
const shader_io = @import("lit_shadow_vs_io.zig");
const shader_externs = @import("lit_shadow_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    // Main-camera clip position (mvp already carries the model transform).
    out.position = mulMatPoint(io_in.u.mvp, io_in.vertex_position);

    // World-space normal via the model's normal matrix (w=0 direction).
    const n: Vec3 = io_in.vertex_normal;
    const wn: Vec = mulMatVec(io_in.u.normal_matrix, vec4(n[0], n[1], n[2], 0.0));
    out.frag_normal = normalize(Vec3{ wn[0], wn[1], wn[2] });

    // Fragment position in the LIGHT's clip space — the FS perspective-
    // divides + remaps this to sample the shadow map.
    out.frag_light_space_pos = mulMatPoint(io_in.u.light_vp, io_in.vertex_position);

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
