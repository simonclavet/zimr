//! src/shaders/depth_write_fs.zig — fragment-shader depth writing,
//! raylib's `depth_write.fs` ported (their `shaders_depth_writing`).
//!
//! The material lies to the depth buffer, on purpose:
//! `frag_depth = 1 - base_color.blue`, raylib's exact gag.  A purple cube
//! (blue ≈ 1) claims to be at depth ≈ 0 and pops in FRONT of
//! everything; a yellow cube (blue = 0) claims depth 1 and sinks
//! BEHIND everything — impossible occlusion that holds up as the
//! camera orbits, which is the whole demo.  This is also the engine's
//! first fragment shader with a `frag_depth` output, the capability
//! the hybrid raster+raymarch example builds on.
//!
//! Vertex stage: `gbuffer_vs`, reused (the forward-material pattern).
//! Schema in `depth_write_fs_io.zig`.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec3 = zm.Vec3;
const clamp01 = zm.clamp01;
const dot = zm.dot;
const normalize = zm.normalize;
const shader_io = @import("depth_write_fs_io.zig");
const shader_externs = @import("depth_write_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

/// Ambient floor so back faces still read as shape.
const ambient: f32 = 0.35;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    // A little Lambert over the flat color — enough shading to see the
    // cube as a cube, not enough to muddy the blue channel's job.
    const normal: Vec3 = normalize(io_in.frag_world_normal);
    const light_dir: Vec3 = normalize(Vec3{
        io_in.u.light_dir[0],
        io_in.u.light_dir[1],
        io_in.u.light_dir[2],
    });
    const lighting: f32 = ambient + (1.0 - ambient) * @max(dot(normal, light_dir), 0.0);

    const shaded: Vec = .{
        io_in.u.base_color[0] * lighting,
        io_in.u.base_color[1] * lighting,
        io_in.u.base_color[2] * lighting,
        1.0,
    };
    out.final_color = shaded;

    // raylib's line — but from the FLAT base blue, not the shaded one.
    // raylib's cubes are unlit, so their finalColor.z IS the flat color:
    // each cube claims exactly ONE depth and purple beats teal on every
    // face.  Our little Lambert exists only for the eye; feeding the
    // shaded blue in here let a bright teal top out-claim a dim purple
    // side (per-face depth wobble — spotted on device).
    out.frag_depth = clamp01(1.0 - io_in.u.base_color[2]);
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
