//! src/shaders/decal_vs.zig — shader-projected decal receiver VS body (IoT).
//!
//! Ported from the direct `@SpirvType` version. Projects the world-space
//! receiver position through the camera view-projection and forwards the world
//! position + normal as varyings (the FS needs the world position to test it
//! against the projector box, the normal for the facing test). Schema in
//! `decal_vs_io.zig`; shared varyings in `decal_common_io.zig`.

const zm = @import("zm");
const mulMatVec = zm.mulMatVec;
const shader_io = @import("decal_vs_io.zig");
const shader_externs = @import("decal_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const p: zm.Vec3 = io_in.p;
    // No depth bias: the decal re-draws the SAME mesh that was drawn as the
    // receiver body, so decal fragment depth is bit-identical to the surface
    // depth. `less_equal` passes for the near surface (shows the decal) and
    // FAILS for the far surface / back side (depth-occluded — no see-through).
    out.position = mulMatVec(io_in.u.vp, .{ p[0], p[1], p[2], 1.0 });
    out.o_world = p;
    out.o_normal = io_in.n;

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
