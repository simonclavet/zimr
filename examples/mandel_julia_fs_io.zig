//! examples/mandel_julia_fs_io.zig - schema for the mandel_julia_fs shader.
//! Declares Inputs / Outputs / Ubo consumed by `mandel_julia_fs.zig`
//! (shader body) and shared with the CPU host.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;

pub const Inputs = struct {
    frag_tex_coord: Vec2,
    // `frag_color` intentionally omitted: this FS computes color from
    // frag_tex_coord + the morph param t, not a vertex color. A varying the
    // trivial fullscreen VS never outputs would fail loadShaderVF's check.
};
pub const Outputs = struct {
    out_color: Vec,
};
pub const Ubo = struct {
    center: Vec2,
    zoom: f32,
    _pad0: f32 = 0,
    resolution: Vec2,
    max_iter: f32,
    /// Morph parameter in [0, 1]: 0=mandelbrot, 1=julia.
    t: f32,
    /// Julia parameter (the `c` constant at t=1).
    julia_c: Vec2,
    _pad1: f32 = 0,
    _pad2: f32 = 0,
};
