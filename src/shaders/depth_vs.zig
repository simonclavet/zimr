//! src/shaders/depth_vs.zig - depth-in-red vertex shader body.
//!
//! Projects the vertex, then computes its depth value and folds it into
//! a grayscale colour the FS emits verbatim. mode 0 stores the raw
//! `ndc_z*0.5+0.5` (shadow-map comparison space, pbr-faithful); nonzero
//! linearizes the NDC depth to a view-space distance and normalizes it
//! against the viz window for a full-contrast visualisation.
//!
//! Same source compiles for SPIR-V (-> WGSL/GLSL -> GPU) and wasm32 (->
//! CPU dispatch). Schema lives in `depth_vs_io.zig`.

const zm = @import("zm");
const Vec = zm.Vec;
const mulMatPoint = zm.mulMatPoint;
const clamp = zm.clamp;
const shader_io = @import("depth_vs_io.zig");
const shader_externs = @import("depth_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const clip: Vec = mulMatPoint(io_in.u.mvp, io_in.vertex_position);
    out.position = clip;

    const inv_w: f32 = 1.0 / clip[3];
    const ndc_z: f32 = clip[2] * inv_w;
    const raw: f32 = ndc_z * 0.5 + 0.5;

    const cam_near: f32 = io_in.u.params[0];
    const cam_far: f32 = io_in.u.params[1];
    const viz_near: f32 = io_in.u.params[2];
    const viz_far: f32 = io_in.u.params[3];
    // Recover view-space distance from the [0,1] NDC depth, then map the
    // [viz_near, viz_far] window onto [0,1] for display contrast.
    const z_view: f32 = (cam_near * cam_far) / (cam_far - ndc_z * (cam_far - cam_near));
    const norm: f32 = (z_view - viz_near) / (viz_far - viz_near);
    const norm_c: f32 = clamp(norm, 0.0, 1.0);

    // mode 0: raw ndc_z*0.5+0.5 (shadow-map, pbr-faithful). mode 2: raw ndc_z
    // ([0,1] full range) - the correct viz for an ORTHOGRAPHIC light, whose
    // NDC depth is already linear (mode 1's perspective linearize would distort
    // it). else (mode 1): perspective linearize + normalize.
    const d: f32 = if (io_in.u.mode == 0) raw else if (io_in.u.mode == 2) ndc_z else norm_c;
    out.frag_gray = .{ d, d, d, 1.0 };

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
