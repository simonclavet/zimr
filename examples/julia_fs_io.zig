//! examples/julia_fs_io.zig — schema for the julia_fs shader.
//! Declares Inputs / Outputs / Ubo consumed by `julia_fs.zig`
//! (shader body) and shared with the CPU host.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;

pub const Inputs = struct {
    frag_tex_coord: Vec2,
    // NOTE: this FS computes color from frag_tex_coord + julia_c and does NOT
    // read a vertex color, so `frag_color` is intentionally NOT declared. A
    // varying the trivial fullscreen VS never outputs would (correctly) fail
    // loadShaderVF's comptime VS↔FS check — see the N6 mandelbrot lesson.
};
pub const Outputs = struct {
    out_color: Vec,
};
pub const Ubo = struct {
    /// View center in complex-plane coordinates.
    center: Vec2,
    /// View scale (1.0 → canvas height spans 4 units of imaginary axis).
    zoom: f32,
    _pad0: f32 = 0,
    /// Canvas pixel dimensions.
    resolution: Vec2,
    /// Iteration cap.
    max_iter: f32,
    _pad1: f32 = 0,
    /// The Julia parameter — complex constant `c` for the iteration.
    julia_c: Vec2,
    /// std140: pad to 16-byte boundary.
    _pad2: f32 = 0,
    _pad3: f32 = 0,
};
