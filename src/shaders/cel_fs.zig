//! src/shaders/cel_fs.zig — cel (toon) shading fragment material.
//!
//! Ordinary Lambert, then the punchline: the diffuse term is snapped to
//! `bands` discrete steps with `floor(x·bands)/bands`, so the smooth
//! falloff becomes flat poster regions with hard borders — the
//! hand-inked look.  An ambient floor keeps the darkest band from
//! going to pure black (ink outlines need something to sit on).
//!
//! Vertex stage: `gbuffer_vs`, reused (the forward-material pattern —
//! see `fog_fs.zig`).  The silhouette outline is NOT here: that's a
//! separate inverted-hull pass (`outline_hull_vs` + `depth_fs`).
//! Schema in `cel_fs_io.zig`.

const zm = @import("zm");
const Vec3 = zm.Vec3;
const dot = zm.dot;
const normalize = zm.normalize;
const shader_io = @import("cel_fs_io.zig");
const shader_externs = @import("cel_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

/// raylib's ambient floor — the darkest band is dim, never black.
const ambient_floor: f32 = 0.08;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const normal: Vec3 = normalize(io_in.frag_world_normal);
    const light_dir: Vec3 = normalize(Vec3{
        io_in.u.light_dir[0],
        io_in.u.light_dir[1],
        io_in.u.light_dir[2],
    });
    const n_dot_l: f32 = @max(dot(normal, light_dir), 0.0);

    // raylib's cel.fs quantization, verbatim: snap NdotL into `bands`
    // plateaus, dividing by bands-1 so the TOP band reaches full 1.0
    // brightness (divide by bands and nothing ever hits white — the
    // whole render reads underexposed; ask us how we know).  The min()
    // guards NdotL == 1.0 from indexing one band past the end.
    const bands: f32 = @max(io_in.u.params[0], 2.0);
    const quantized: f32 = @min(@floor(n_dot_l * bands), bands - 1.0) / (bands - 1.0);

    // Ambient floor + the banded light, clamped — raylib's lightAccum.
    const lighting: f32 = @min(ambient_floor + quantized, 1.0);

    out.final_color = .{
        io_in.u.base_color[0] * lighting,
        io_in.u.base_color[1] * lighting,
        io_in.u.base_color[2] * lighting,
        1.0,
    };
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
