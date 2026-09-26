//! src/shaders/skybox_vs.zig - gradient-skybox VS body (IoT).
//!
//! Ported from the direct `@SpirvType` version. Emits a fullscreen triangle,
//! unprojects each NDC corner at z=1 through `inv_view_proj` to a world-space
//! view ray from the camera, and forwards the ray + the two sky colours to the
//! FS (so the FS needs no UBO). Schema in `skybox_vs_io.zig`.

const zm = @import("zm");
const mulMatVec = zm.mulMatVec;
const shader_io = @import("skybox_vs_io.zig");
const shader_externs = @import("skybox_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    // Fullscreen triangle in NDC: (-1,-1), (3,-1), (-1,3).
    const vi: u32 = io_in.vertex_index();
    const cx: f32 = if (vi == 1) 3.0 else -1.0;
    const cy: f32 = if (vi == 2) 3.0 else -1.0;

    // Push to the far plane so the skybox sits behind everything.
    out.position = .{ cx, cy, 0.999999, 1.0 };

    // Unproject the corner to a world-space ray from the camera.
    const uu = io_in.u;
    const far: zm.Vec = mulMatVec(uu.inv_view_proj, .{ cx, cy, 1.0, 1.0 });
    const w: f32 = far[3];
    out.dir = .{
        far[0] / w - uu.camera_pos[0],
        far[1] / w - uu.camera_pos[1],
        far[2] / w - uu.camera_pos[2],
    };
    out.sky_bottom = uu.sky_bottom;
    out.sky_top = uu.sky_top;

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
