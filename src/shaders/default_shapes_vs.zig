//! src/shaders/default_shapes_vs.zig — Zig source for the wgpu
//! engine's default 2D vertex shader.  Replaces the hand-written
//! the engine-emitted `default_shapes_vs.wgsl` —
//! same effect (transform vertex through `view_projection`, pass
//! UV + color through), now compiled through the typed shader
//! pipeline → SPIR-V → spv2wgsl → embedded `.wgsl`.  See
//! `src/notes/webgpu-migration-plan.md` §3 Phase C for context.
//!
//! Same source runs on:
//!   - SPIR-V (→ WGSL via spv2wgsl → @embedFile → wgpu pipeline)
//!   - SPIR-V (→ GLSL via spirv-cross → @embedFile → WebGL2 pipeline)
//!     when emit_wgsl is opted out (legacy path during transition)
//!   - wasm32 / x86_64 (CPU dispatcher in `raster_shader.zig`)
//!
//! The schema lives in `default_shapes_vs_io.zig` (Attributes,
//! Ubo, Outputs); the interpolated varyings live in
//! `default_shapes_common_io.zig` so they're declared exactly
//! once and shared with the fragment stage.

const zm = @import("zm");
const Vec = zm.Vec;
const mulMatVec = zm.mulMatVec;
const vec4 = zm.vec4;
const shader_io = @import("default_shapes_vs_io.zig");
const shader_externs = @import("default_shapes_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

/// The pure-logic kernel.  Same shape as the fragment-stage
/// `shaderMain` (see `examples/mandelbrot_fs.zig` for the canonical
/// example of the IoT/Out pattern): takes inputs by value, returns
/// outputs by value.  Both GPU (SPIR-V) and CPU (`raster_shader.
/// dispatchVertexShader`) entry points use this.
///
/// `out.position` is the clip-space vec4 the rasterizer needs;
/// codegen wires the field to SPIR-V's `Position` builtin output
/// automatically (see `tools/gen_shader_externs.zig` line ~577).
/// `out.uv` and `out.color` are pass-through varyings to the
/// fragment stage.
pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    // Project vertex from 2D screen-space through the view-projection
    // matrix.  Position is vec2; lift to vec4 with z=0, w=1 (point,
    // not direction) so the matrix multiplication is well-defined and
    // the perspective divide downstream is a no-op.  This is the same
    // computation the legacy hand-written WGSL did:
    //   out.position = per_frame.view_projection * vec4<f32>(in.pos, 0.0, 1.0);
    const pos4: Vec = vec4(
        io_in.vertex_position[0],
        io_in.vertex_position[1],
        0.0,
        1.0,
    );
    out.position = mulMatVec(io_in.u.view_projection, pos4);

    // Varyings pass through unchanged — interpolation across the
    // triangle happens in the rasterizer.
    out.frag_tex_coord = io_in.vertex_tex_coord;
    out.frag_color = io_in.vertex_color;

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
