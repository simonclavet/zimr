//! src/shaders/effect_tiling_fs.zig — texture tiling, raylib's `tiling.fs`
//! ported (their `shaders_texture_tiling`).
//!
//! raylib's body is one line: `finalColor = texture(texture0, uv*tiling)`,
//! relying on a REPEAT-address sampler to wrap. The source here is the
//! scene render-texture whose sampler is CLAMP, so we wrap the coordinate
//! in-shader with `uv - floor(uv)` (fract) — the rendered scene then
//! repeats `tiling.x`×`tiling.y` across the quad without a sampler change.
//! (The source RT has a single mip, so the fract seam's derivative spike
//! selects no wrong LOD.)

const zm = @import("zm");
const Vec2 = zm.Vec2;
const shader_io = @import("effect_tiling_fs_io.zig");
const shader_externs = @import("effect_tiling_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;
pub const TextureRef = shader_externs.TextureRef;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const tiling: Vec2 = .{ io_in.u.tiling[0], io_in.u.tiling[1] };
    const scaled: Vec2 = io_in.frag_uv * tiling;
    const uv: Vec2 = scaled - @floor(scaled);

    out.final_color = io_in.texture0(uv);
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
