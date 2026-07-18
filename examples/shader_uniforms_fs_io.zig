//! examples/shader_uniforms_fs_io.zig — schema for the shader_uniforms_fs shader.
//! Declares Inputs / Outputs / Ubo consumed by `shader_uniforms_fs.zig`
//! (shader body) and shared with the CPU host.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;

pub const Inputs = struct {
    frag_tex_coord: Vec2,
    frag_color: Vec,
};
pub const Outputs = struct {
    out_color: Vec,
};
pub const Ubo = struct {
    /// Cursor position in the same pixel-units as `resolution` —
    /// the host pushes logical (CSS) pixels here.
    mouse: Vec2,
    /// Canvas size in pixels (same unit as `mouse`).
    resolution: Vec2,
    /// Seconds since program start.  Drives the hue scroll and the
    /// radial-wobble term.
    time: f32,
    // Trailing pad to round the block up to vec4 alignment (32B).
    // Individual `f32` fields — not `[3]f32` — because std140 arrays
    // of float pad each element to vec4 stride, breaking parity with
    // Zig's natural array packing.
    _pad1: f32 = 0,
    _pad2: f32 = 0,
    _pad3: f32 = 0,
};
