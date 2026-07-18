//! src/shaders/lit_shadow_common_io.zig — Interp varyings shared by
//! `lit_shadow_vs` and `lit_shadow_fs`.
//!
//! Binding model (which @group each uniform/sampler lands in) is the
//! stage-segregated scheme documented in src/zimr.zig §3:
//! VS uniforms→group 0, samplers→group 1, FS uniforms→group 2.
//!
//! The shadow pipeline: world-space normal for Lambert diffuse, plus
//! the fragment's position in the LIGHT's clip space so the FS can
//! project into shadow-map UV + compare depth. Single source of truth
//! — VS Outputs and FS Inputs both alias this.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec3 = zm.Vec3;

/// Interpolated values flowing from `lit_shadow_vs` to `lit_shadow_fs`.
/// Order matters: each field index is its `layout(location = N)`
/// decoration on both stages.
pub const Interp = struct {
    frag_normal: Vec3,
    frag_light_space_pos: Vec,
};
