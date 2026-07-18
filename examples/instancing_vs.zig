//! examples/instancing_vs.zig — instancing vertex shader body.
//!
//! Adds the per-instance offset to the per-vertex triangle position, transforms
//! by the UBO's 4x4 aspect matrix, and passes the per-instance colour through.
//! One draw call replays the 3-vertex triangle `instance_count` times; the
//! offset/colour attributes advance once per instance (step mode set host-side).

const zm = @import("zm");
const Vec2 = zm.Vec2;
const Vec3 = zm.Vec3;
const mulMatPoint = zm.mulMatPoint;
const shader_io = @import("instancing_vs_io.zig");
const shader_externs = @import("instancing_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    // Per-vertex shape + per-instance placement, on the z=0 plane.
    const p: Vec2 = io_in.vertex_position;
    const off: Vec2 = io_in.instance_offset;
    const world: Vec3 = .{ p[0] + off[0], p[1] + off[1], 0.0 };
    out.position = mulMatPoint(io_in.u.transform, world);

    const c: Vec3 = io_in.instance_color;
    out.frag_color = .{ c[0], c[1], c[2], 1.0 };

    return out;
}

comptime {
    _ = shader_io;
    _ = shader_externs.installSpirvEntry(shaderMain);
}
