//! src/shaders/pbr_common_io.zig - constants + Interp varyings
//!
//! Binding model (which @group each uniform/sampler lands in) is the
//! stage-segregated scheme documented in src/zimr.zig section 3:
//! VS uniforms->group 0, samplers->group 1, FS uniforms->group 2.
//! shared by `pbr_vs_io` and `pbr_fs_io`.
//!
//! Phase 4a of `src/notes/typesafe_zig_shaders.md`.  Same "rename in
//! one place" pattern as `unlit_common_io.zig`: VS's `Outputs` and
//! FS's `Inputs` both alias `Interp` here, so renaming a varying
//! propagates to both stages.
//!
//! `max_directional_lights` and `max_point_lights` are also lifted
//! here so the iface schemas can use them to size the light-uniform
//! arrays.  The shader bodies (`pbr_vs.zig`, `pbr_fs.zig`) currently
//! duplicate the constants for use in `for (0..MAX_*) |i|` loops;
//! a follow-up turn can wire the constants through `ext` if the
//! duplication becomes a maintenance burden.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const Vec3 = zm.Vec3;

/// Maximum directional lights uploaded per draw.  Drives the size of
/// `directional_light_dir`, `directional_light_color`, plus the body's
/// iteration count when computing lighting.  Two is enough for the
/// usual key+fill setup; bumping this requires rebuilding the FS.
pub const max_directional_lights: u32 = 2;

/// Maximum point lights uploaded per draw.  Drives the size of
/// `point_light_pos`, `point_light_color`, `point_light_range`.
pub const max_point_lights: u32 = 4;

/// Interpolated values that flow from `pbr_vs` to `pbr_fs`.  Order
/// matters: the field index becomes the `layout(location = N)`
/// decoration on both sides.  Rename or reorder here propagates to
/// both stages - but it's still a SPIR-V layout break, so any
/// mismatch with currently-loaded shaders requires rebuilding both.
pub const Interp = struct {
    frag_world_pos: Vec3,
    frag_world_normal: Vec3,
    frag_tex_coord: Vec2,
    /// vertex_color passed through.  Default mesh paths supply
    /// (1,1,1,1) for meshes without a COLOR_0 attribute.
    frag_color: Vec,
    /// `light_space_matrix * world_pos`.  Used by `computeShadow` to
    /// look up the depth comparison in the shadow map.
    frag_light_space_pos: Vec,
    /// World-space tangent + handedness (xyz: direction, w: +/-1).
    /// FS reconstructs bitangent as `cross(N, T) * w` for the TBN
    /// matrix that brings sampled normal-map vectors into world space.
    frag_world_tangent: Vec,
};
