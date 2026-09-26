//! src/shaders/cube3d_vs.zig - immediate-mode 3D batch vertex shader body.
//!
//! Vertices arrive already in world space (the per-primitive model transform
//! was applied on the CPU during batching), so this stage only projects them
//! through the camera view-projection and evaluates a single fixed directional
//! light with a 0.35 ambient floor - folding the result into the colour the
//! fragment stage emits. Since cube faces carry constant per-face normals, the
//! per-vertex evaluation is exactly flat shading.
//!
//! Same source compiles for SPIR-V (-> WGSL/GLSL -> GPU) and wasm32 (-> CPU
//! dispatch). Schema lives in `cube3d_vs_io.zig`.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec3 = zm.Vec3;
const dot = zm.dot;
const mulMatPoint = zm.mulMatPoint;
const normalize = zm.normalize;
const shader_io = @import("cube3d_vs_io.zig");
const shader_externs = @import("cube3d_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    // World-space position straight through the camera view-projection.
    out.position = mulMatPoint(io_in.u.view_projection, io_in.vertex_position);

    // Lambert against a fixed world-space light, 0.35 ambient floor.
    const nrm: Vec3 = normalize(io_in.vertex_normal);
    const light_dir: Vec3 = normalize(Vec3{ 0.36, 0.80, 0.48 });
    const n_dot_l: f32 = @max(dot(nrm, light_dir), 0.0);
    const lighting: f32 = 0.35 + 0.65 * n_dot_l;

    const c: Vec = io_in.vertex_color;
    out.frag_color = .{ c[0] * lighting, c[1] * lighting, c[2] * lighting, c[3] };

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
