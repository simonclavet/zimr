//! examples/trivial_fs_io.zig — schema for the trivial FS used
//! by the wgpu_bringup to validate Phase D1.
//!
//! Carries a tiny Ubo (one f32: time) to validate the typed UBO
//! path in loadShader — the wgpu-side equivalent of "make sure
//! the bind group + buffer creation + queueWriteBuffer dance works
//! end-to-end."  Empty Ubo would skip those code paths entirely.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;

/// Varying inputs from the VS — must match `trivial_vs_io.Outputs`.
pub const Inputs = struct {
    frag_tex_coord: Vec2,
};

/// Single-uniform Ubo.  `time` modulates the output color so the
/// `loadShader → pushUbo` round-trip is visually verifiable in a
/// real-browser smoke run later (the smoke harness just verifies no
/// traps; visual output needs a real WebGPU runtime).
///
/// std140: a single f32 padded to vec4 — three trailing pad floats
/// so `@sizeOf(Ubo) % 16 == 0`.  The comptime guard in
/// `UniformBuffer(T)` would catch a missing pad.
pub const Ubo = struct {
    time: f32,
    _pad0: f32 = 0,
    _pad1: f32 = 0,
    _pad2: f32 = 0,
};

/// Stage output — RGBA color.
pub const Outputs = struct {
    out_color: Vec,
};
