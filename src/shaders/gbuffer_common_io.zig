//! src/shaders/gbuffer_common_io.zig - varyings shared by `gbuffer_vs`
//! and `gbuffer_fs`.
//!
//! Deferred rendering, pass 1 of 2: instead of lighting fragments as we
//! rasterize, we write everything the lighting math will need into a fat
//! "G-buffer" (three textures), and light the whole screen in one later
//! pass.  The only things geometry has to hand the fragment stage are its
//! WORLD-space position and normal - lighting happens in world space, so
//! we interpolate world-space values and never look back at clip space.
//!
//! Binding model is the stage-segregated scheme from src/zimr.zig section 3:
//! VS uniforms->group 0, samplers->group 1, FS uniforms->group 2.

const zm = @import("zm");
const Vec3 = zm.Vec3;

/// Interpolated values flowing from `gbuffer_vs` to `gbuffer_fs`.
/// Field order matters: index N is `layout(location = N)` on both stages.
pub const Interp = struct {
    /// Where this fragment sits in the world - pass 2 reconstructs light
    /// directions and view vectors from it, per pixel.
    frag_world_pos: Vec3,
    /// The surface normal in world space (normal-matrix transformed;
    /// re-normalized in the FS because interpolation shortens it).
    frag_world_normal: Vec3,
};
