//! src/shaders/decal_fs.zig - shader-projected decal receiver FS body (IoT).
//!
//! Ported from the direct `@SpirvType` version. For each receiver fragment:
//! transform its world position by the decal PROJECTOR (world -> decal box
//! space), and if it lands inside the box `[-s, s]^3` paint the decal texture at
//! the planar box-space XY. Fragments outside the box (or facing away) get
//! zero alpha, so a decal "paints" exactly the surface patch under its
//! projector - no mesh clipping, scales to any mesh density.
//!
//! Sample discipline: `textureSample` needs screen-space derivatives, which
//! WGSL/Tint forbid inside non-uniform branches - so we sample UNCONDITIONALLY
//! at uniform control flow, then MASK the result with arithmetic (value-select)
//! inside-box + facing terms. Nothing branches around the sample.
//!
//! Schema in `decal_fs_io.zig` (projector UBO pinned to group 1, decal texture
//! pinned to group 2).

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const Vec3 = zm.Vec3;
const mulMatVec = zm.mulMatVec;
const clamp01 = zm.clamp01;
const normalize = zm.normalize;
const shader_io = @import("decal_fs_io.zig");
const shader_externs = @import("decal_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

/// The fragment-stage uniform type, re-exported so a CPU consumer (the decal
/// side-by-side) can build the same `Ubo` the GPU pipeline's std140 block is
/// generated from - one definition, both renderers.
pub const Ubo = shader_io.Ubo;

/// The CPU-side texture handle the software rasterizer samples through, so a
/// side-by-side can feed the decal texture to `io.decal(uv)` on the CPU path.
pub const TextureRef = shader_externs.TextureRef;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const w: Vec3 = io_in.o_world;
    // World -> decal box space.
    const box: Vec = mulMatVec(io_in.u.projector, .{ w[0], w[1], w[2], 1.0 });

    // Sample UNCONDITIONALLY at uniform control flow, then mask (see header).
    const inv_size: f32 = io_in.u.params[1];
    const uv: Vec2 = .{
        clamp01(box[0] * inv_size + 0.5),
        clamp01(box[1] * inv_size + 0.5),
    };
    const t: Vec = io_in.decal(uv);

    // Box membership as a 0/1 mask (no branch): 1 inside [-half, half]^3, else 0.
    const half: f32 = io_in.u.params[0];
    const inside: f32 = axisMask(box[0], half) * axisMask(box[1], half) * axisMask(box[2], half);

    // Facing mask: only paint surfaces whose normal faces TOWARD the projector.
    const nrm: Vec3 = normalize(io_in.o_normal);
    const facing: f32 = ndotf(nrm, io_in.u.forward);

    const c: Vec = io_in.u.color;
    const a: f32 = t[3] * c[3] * inside * facing;
    out.final_color = .{ t[0] * c[0], t[1] * c[1], t[2] * c[2], a };

    return out;
}

/// `1.0` when `|x| <= half`, else `0.0` - one axis of the box-membership test
/// as an arithmetic mask (a value-select, so the sample stays at uniform
/// control flow; nothing branches around the `textureSample`).
fn axisMask(x: f32, half: f32) f32 {
    return if (@abs(x) <= half) 1.0 else 0.0;
}

/// `1.0` when the surface (normal `n`) faces toward the projector, else `0.0`.
/// `fwd` is the surface normal at the hit - it points OUTWARD from the target.
/// A fragment on the SAME (near) surface has its own outward normal pointing the
/// same way, so `dot(n, fwd) > 0`; the far wall points the opposite way. Keep
/// the front side, with a small negative threshold so nearly edge-on faces
/// still count. Value-select, not control flow.
fn ndotf(n: Vec3, fwd: Vec) f32 {
    const d: f32 = n[0] * fwd[0] + n[1] * fwd[1] + n[2] * fwd[2];
    return if (d > -0.1) 1.0 else 0.0;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
