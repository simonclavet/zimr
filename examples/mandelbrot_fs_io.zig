//! examples/mandelbrot_fs_io.zig - schema for the Mandelbrot
//! fragment shader.  Declares the data interface (Inputs, Outputs,
//! Ubo) consumed by `mandelbrot_fs.zig` and shared with the CPU
//! host `mandelbrot.zig` / `mandelbrot_split.zig`.
//!
//! There is only ONE human-edited declaration of each shape; codegen
//! reflects on this file to emit a matching extern block for the
//! shader body, and the CPU side imports this file directly.  Drift
//! between sides is impossible.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;

/// Varying inputs from the engine default VS.  Field names + order
/// MUST match `src/shaders/default_common_io.zig`'s `Interp`.
pub const Inputs = struct {
    frag_tex_coord: Vec2,
    // NOTE: this FS computes its own color from frag_tex_coord and does NOT
    // read a vertex color, so `frag_color` is intentionally NOT declared. (It
    // was previously here to mirror the 2D vertex format, but an FS must only
    // declare the varyings it consumes - otherwise its @location inputs don't
    // match a minimal fullscreen VS's outputs, and WebGPU rejects the pipeline.)
};

/// Stage output - the rendered fractal colour.
pub const Outputs = struct {
    out_color: Vec,
};

/// UBO layout.  std140 alignment rules: vec2 needs 8-byte alignment,
/// the whole block must round to vec4 (16-byte) alignment.  Explicit
/// `_padN` fields enforce the right offsets - the comptime check in
/// `UniformBuffer(T)` catches "forgot trailing pad" drift via
/// `@sizeOf(T) % 16 == 0`.
pub const Ubo = struct {
    /// Complex-plane center the view is anchored at.
    center: Vec2,
    /// View scale (1.0 -> canvas height spans 4 units of imaginary axis).
    zoom: f32,
    /// std140: vec2 needs 8-byte alignment, so we pad 4 bytes here
    /// before `resolution`.
    _pad0: f32 = 0,
    /// Canvas pixel size, used to undo the pixel grid.
    resolution: Vec2,
    /// Iteration cap.  GLSL ES needs a constant loop bound, so the
    /// shader's `for` runs to 1024; this is the runtime gate.
    max_iter: f32,
    /// std140: struct size must round to 16 bytes.
    _pad1: f32 = 0,
};
