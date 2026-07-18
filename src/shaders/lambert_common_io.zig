//! src/shaders/lambert_common_io.zig — Interp varyings shared by
//!
//! Binding model (which @group each uniform/sampler lands in) is the
//! stage-segregated scheme documented in src/zimr.zig §3:
//! VS uniforms→group 0, samplers→group 1, FS uniforms→group 2.
//! `lambert_vs` and `lambert_fs`.
//!
//! Lambertian diffuse + ambient.  Adds a world-space normal varying
//! to unlit's tex-coord-only shape.  Single source of truth — VS
//! Outputs and FS Inputs both alias this.

const zm = @import("zm");
const Vec2 = zm.Vec2;
const Vec3 = zm.Vec3;

/// Interpolated values flowing from `lambert_vs` to `lambert_fs`.
/// Order matters: each field index is its `layout(location = N)`
/// decoration on both stages.
pub const Interp = struct {
    frag_tex_coord: Vec2,
    frag_normal: Vec3,
};
