//! src/shaders/hybrid_raymarch_fs_io.zig — raymarched-scene fragment
//! shader schema.  Companion to `hybrid_raymarch_fs.zig`.
//!
//! A fullscreen quad (vertex stage = `deferred_shading_vs`, reused)
//! whose fragment shader IS a renderer: it builds a camera ray per
//! pixel, sphere-traces an SDF scene, shades the hit — and writes the
//! hit's TRUE depth via the FragDepth builtin, projected through the
//! same view-projection the rasterized geometry uses.  That last part
//! is the whole point: raster cubes and raymarched blobs occlude each
//! other correctly because they speak the exact same depth, by
//! construction (raylib's hybrid demo instead teaches BOTH shaders a
//! custom near/far linearization and hopes they match).

const zm = @import("zm");
const Vec = zm.Vec;
const common = @import("deferred_shading_common_io.zig");

/// Interpolated inputs — the fullscreen quad's UV, verbatim.
pub const Inputs = common.Interp;

/// FS uniform block (group 2, one binding).
pub const Ubo = struct {
    /// The camera's view-projection — the SAME matrix the raster pass
    /// uses, so `frag_depth = project(hit).z/w` needs no translation.
    vp: [4]Vec,
    /// Camera position, world space (.w spare).
    view_pos: Vec,
    /// Camera basis: the ray fan is fwd + right·x + up·y.
    cam_right: Vec,
    cam_up: Vec,
    /// .w carries tan(fov_y / 2).
    cam_fwd: Vec,
    /// {aspect, time, 0, 0} — time animates the metaballs.
    params: Vec,
};

/// Color at location 0 + the FragDepth builtin (`frag_depth` is the
/// magic name — no location, decorated BuiltIn FragDepth).
pub const Outputs = struct {
    final_color: Vec,
    frag_depth: f32,
};
