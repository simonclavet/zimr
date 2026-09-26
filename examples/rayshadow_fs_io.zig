//! examples/rayshadow_fs_io.zig - schema for the ray-traced hard-shadow shader.
//!
//! The SAME `shaderMain` (rayshadow_fs.zig) compiles to WGSL (GPU), to native
//! Zig (the raster software dispatcher), and runs at comptime (baked corner) -
//! one shader, three execution targets. It ray-traces a ground plane + two
//! boxes lit by one directional light, casting HARD SHADOWS via a shadow ray
//! (no shadow map: the shadow test is a second ray-scene intersection, which is
//! why it runs identically on all three targets). The camera basis is
//! precomputed host-side; the shader rebuilds the per-pixel ray from it.
const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;

pub const Inputs = struct {
    frag_tex_coord: Vec2,
};

pub const Outputs = struct {
    out_color: Vec,
};

pub const Ubo = struct {
    // Camera basis (precomputed host-side; the shader rebuilds the per-pixel ray).
    cam_origin: Vec, // xyz eye, w unused
    px00: Vec, // centre of the top-left pixel (world)
    pdu: Vec, // one pixel right (world)
    pdv: Vec, // one pixel down (world)

    resolution: Vec2, // render target px (x, y)
    _pad0: f32 = 0, // the orbit lives in the camera basis (cam_origin/px00/pdu/pdv)
    _pad1: f32 = 0,
};
