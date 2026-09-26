//! examples/raycube_fs_io.zig - schema for the ray-traced-cube fragment shader.
//!
//! The SAME `shaderMain` (raycube_fs.zig) compiles to WGSL (GPU), to native Zig
//! (the raster software dispatcher), and runs at comptime (baked corner) - one
//! shader, three execution targets, like rt_fs but rendering a rotating cube via
//! a ray-box intersection. The camera basis is precomputed host-side; the shader
//! just rebuilds the per-pixel ray from it.
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
