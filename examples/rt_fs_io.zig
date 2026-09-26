//! examples/rt_fs_io.zig - schema for the ray-tracing fragment shader.
//!
//! Declares Inputs / Outputs / Ubo. The SAME `shaderMain` (rt_fs.zig) compiles
//! to WGSL for the GPU and to native Zig for the raster software dispatcher, so a
//! side-by-side demo can run one shader on both backends. Everything the trace
//! needs - camera basis + the sphere scene - lives in the Ubo (fixed-size
//! arrays, which both WGSL and the raster dispatcher handle).
//!
//! Materials are encoded compactly: each sphere carries an albedo (rgb), a
//! radius, a center, and a `mat` scalar selecting lambertian (0) / metal (1) /
//! dielectric (2), plus a `param` (metal fuzz, or dielectric IOR).

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;

pub const Inputs = struct {
    frag_tex_coord: Vec2,
};

pub const Outputs = struct {
    out_color: Vec,
};

/// Max spheres the shader iterates. Fixed (UBO arrays are fixed-size); unused
/// slots have radius 0 and are skipped.
pub const max_spheres: u32 = 8;

pub const Ubo = struct {
    // Camera basis (precomputed host-side; the shader just rebuilds rays).
    cam_origin: Vec, // xyz eye, w unused
    px00: Vec, // center of the top-left pixel (world)
    pdu: Vec, // one pixel right (world)
    pdv: Vec, // one pixel down (world)

    resolution: Vec2, // render target px (x,y)
    frame_seed: f32, // changes per frame to vary sampling
    sphere_count: f32, // active spheres (<= max_spheres)

    // Scene as FLAT vec4 arrays (the shader codegen supports [N]@Vector(4,f32)
    // but NOT [N]struct). Per sphere i:
    //   sphere_geom[i]   = (cx, cy, cz, radius)
    //   sphere_albedo[i] = (r, g, b, material)  material: 0 lambert,1 metal,2 glass
    //   sphere_extra[i]  = (param, _, _, _)     param: metal fuzz or dielectric IOR
    sphere_geom: [max_spheres]Vec,
    sphere_albedo: [max_spheres]Vec,
    sphere_extra: [max_spheres]Vec,
};
