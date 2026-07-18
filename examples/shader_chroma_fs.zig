//! examples/shader_chroma_fs.zig — chroma-shift fragment shader.
//!
//! Same effect across two pipelines: sample R/G/B channels at
//! horizontally-offset UV positions where the offset is animated
//! sinusoidally by `u_time` and scaled by `u_offset`.  At `t=0` (or
//! whenever sin(t)=0) the output collapses to the un-shifted sample.
//!
//! The same `shaderMain` runs on GPU (via SPIR-V → GLSL) and CPU
//! (via `raster_shader.dispatchFragmentShader`).  See
//! `examples/shader_chroma_split.zig` for the side-by-side composite.
//!
//! Schema lives in `shader_chroma_fs_io.zig`.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const shader_io = @import("shader_chroma_fs_io.zig");
const shader_externs = @import("shader_chroma_fs_externs");

// IoT(void) — chroma has no Ubo.  Sampler bindings + loose uniforms
// (col_diffuse, u_offset, u_time) live directly on Io.
pub const Io = shader_externs.IoT(void);
pub const Out = shader_externs.Out;
pub const TextureRef = shader_externs.TextureRef;

comptime {
    _ = shader_io;
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    // Pulse the chroma offset between 0 and u_offset as time advances.
    const t: f32 = 0.5 + 0.5 * @sin(io_in.u_time * 2.0);
    const o: f32 = io_in.u_offset * t;

    // Sample the same texture three times at offset UVs; pick a
    // single channel per sample to fake a chromatic-aberration look.
    const uv_r: Vec2 = .{ io_in.frag_tex_coord[0] + o, io_in.frag_tex_coord[1] };
    const uv_g: Vec2 = io_in.frag_tex_coord;
    const uv_b: Vec2 = .{ io_in.frag_tex_coord[0] - o, io_in.frag_tex_coord[1] };

    const r: f32 = io_in.texture0(uv_r)[0];
    const g: f32 = io_in.texture0(uv_g)[1];
    const b: f32 = io_in.texture0(uv_b)[2];

    // Multiply by col_diffuse and the per-vertex colour, same as the
    // prior GLSL.  In this demo the per-vertex colour is white
    // (rlColor4ub(255,255,255,255)) so this is effectively just
    // `* col_diffuse`, but keeping it preserves behaviour for any
    // future caller that does set a per-vertex colour.
    out.final_color = Vec{ r, g, b, 1.0 } * io_in.col_diffuse * io_in.frag_color;
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
