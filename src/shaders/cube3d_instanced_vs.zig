//! src/shaders/cube3d_instanced_vs.zig - instanced 3D vertex shader body.
//!
//! Reconstructs the per-instance model matrix from its four instance-step vec4
//! columns, transforms the local mesh vertex into world space, then projects it
//! through the camera view-projection. Lighting matches cube3d_vs exactly (one
//! fixed directional light, 0.35 ambient floor, flat per-face normals), so the
//! shared `cube3d_fs` shades instanced and immediate geometry identically.
//!
//! Same source compiles for SPIR-V (-> WGSL -> GPU) and wasm32 (-> CPU dispatch).
//! Schema lives in `cube3d_instanced_vs_io.zig`.

const zm = @import("zm");
const Mat = zm.Mat;
const Vec = zm.Vec;
const Vec3 = zm.Vec3;
const dot = zm.dot;
const mulMat = zm.mulMat;
const mulMatPoint = zm.mulMatPoint;
const mulMatVec = zm.mulMatVec;
const normalize = zm.normalize;
const shader_io = @import("cube3d_instanced_vs_io.zig");
const shader_externs = @import("cube3d_instanced_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    // Rebuild the per-instance model matrix from its four columns (column-major,
    // matching the host's InstanceVertex layout in draw3d.zig).
    const model: Mat = .{
        io_in.instance_model_c0,
        io_in.instance_model_c1,
        io_in.instance_model_c2,
        io_in.instance_model_c3,
    };
    const mvp: Mat = mulMat(io_in.u.view_projection, model);
    out.position = mulMatPoint(mvp, io_in.vertex_position);

    // Normal to world space (direction, w = 0). Cubes use uniform scale, so the
    // model matrix's upper-3x3 is fine without an inverse-transpose.
    const n_local: Vec = .{ io_in.vertex_normal[0], io_in.vertex_normal[1], io_in.vertex_normal[2], 0.0 };
    const n_world: Vec = mulMatVec(model, n_local);
    const nrm: Vec3 = normalize(Vec3{ n_world[0], n_world[1], n_world[2] });

    const light_dir: Vec3 = normalize(Vec3{ 0.36, 0.80, 0.48 });
    const n_dot_l: f32 = @max(dot(nrm, light_dir), 0.0);
    const lighting: f32 = 0.35 + 0.65 * n_dot_l;

    const c: Vec = io_in.instance_color;
    out.frag_color = .{ c[0] * lighting, c[1] * lighting, c[2] * lighting, c[3] };

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
