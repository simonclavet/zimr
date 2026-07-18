//! src/shaders/gbuffer_vs.zig — G-buffer vertex shader body.
//!
//! Deferred pass 1's vertex stage is deliberately boring: project the
//! vertex for the rasterizer, and hand the fragment stage the two
//! world-space facts (position + normal) it will stash in the G-buffer.
//! All the interesting lighting work happens screens later, in
//! `deferred_shading_fs`, reading these values back out of textures.
//!
//! Same source compiles for SPIR-V (→ WGSL → GPU) and for the CPU
//! (`shaderMain` called per vertex).  Schema in `gbuffer_vs_io.zig`.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec3 = zm.Vec3;
const mulMatPoint = zm.mulMatPoint;
const mulMatVec = zm.mulMatVec;
const vec4 = zm.vec4;
const shader_io = @import("gbuffer_vs_io.zig");
const shader_externs = @import("gbuffer_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    // Clip position: the usual one-liner.
    out.position = mulMatPoint(io_in.u.mvp, io_in.vertex_position);

    // World position: model matrix only — this is the value the lighting
    // pass reads back per pixel to build light/view vectors.
    const world: Vec = mulMatPoint(io_in.u.model, io_in.vertex_position);
    out.frag_world_pos = Vec3{ world[0], world[1], world[2] };

    // World normal via the normal matrix (w=0: direction, not point).
    // NOT normalized here — interpolation would shorten it anyway, so the
    // FS normalizes once where it matters.
    const n: Vec3 = io_in.vertex_normal;
    const wn: Vec = mulMatVec(io_in.u.normal_matrix, vec4(n[0], n[1], n[2], 0.0));
    out.frag_world_normal = Vec3{ wn[0], wn[1], wn[2] };

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
