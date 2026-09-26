//! src/shaders/gbuffer_fs.zig - G-buffer fragment shader body.
//!
//! Deferred pass 1's fragment stage doesn't light anything.  It's a
//! stenographer: write down where the surface is, which way it faces,
//! and what it's made of - three outputs, three textures, done.  Pass 2
//! (`deferred_shading_fs`) reads those textures and does ALL the
//! lighting exactly once per screen pixel, no matter how much geometry
//! overdrew here.
//!
//! This is the engine's first MULTI-OUTPUT fragment shader: `Out` has
//! three vec4 fields, each landing in its own MRT color attachment
//! (locations 0/1/2 by field order).  Schema in `gbuffer_fs_io.zig`.

const zm = @import("zm");
const Vec3 = zm.Vec3;
const normalize = zm.normalize;
const shader_io = @import("gbuffer_fs_io.zig");
const shader_externs = @import("gbuffer_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    // Location 0: world position, straight through.  (raylib stores
    // positions too - with the same "reconstruct-from-depth would be
    // better" caveat.  Storing is the simple, readable version; the
    // reconstruction trick can be its own example someday.)
    out.g_world_pos = .{
        io_in.frag_world_pos[0],
        io_in.frag_world_pos[1],
        io_in.frag_world_pos[2],
        1.0,
    };

    // Location 1: world normal, re-normalized - interpolating between
    // per-vertex normals shortens the vector across the triangle, and
    // the lighting pass wants honest unit vectors for its dot products.
    const n: Vec3 = normalize(io_in.frag_world_normal);
    out.g_world_normal = .{ n[0], n[1], n[2], 1.0 };

    // Location 2: the material vec4 (albedo.rgb + spec.a), verbatim.
    out.g_albedo_spec = io_in.u.albedo_spec;

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
