//! src/shaders/lambert_vs_io.zig - typed interface for the Lambert
//!
//! Binding model (which @group each uniform/sampler lands in) is the
//! stage-segregated scheme documented in src/zimr.zig section 3:
//! VS uniforms->group 0, samplers->group 1, FS uniforms->group 2.
//! vertex shader.  Companion to `lambert_vs.zig`.
//!
//! Lambertian-lit pipeline: position via MVP, world-space normal via
//! `mat3(mat_model)`, texcoord passthrough.  The world-space normal
//! transform uses `mat_model` directly (not its inverse-transpose),
//! so non-uniform mesh scale will skew lighting - same behavior as
//! the prior `lambert.vs.glsl` it replaces.
//!
//! Migrated from `examples/shared/shaders/lambert.vs.glsl` as part
//! of the catalog-shader migration to the typed shader pipeline.

const shader = @import("shader_interface");
const common = @import("lambert_common_io.zig");

/// Vertex attributes consumed by this stage.  Locations match
/// raylib's `RL_DEFAULT_SHADER_ATTRIB_LOCATION_*` constants:
/// position=0, texcoord=1, normal=2.  No vertex color or tangent -
/// Lambert is a simple shader and doesn't need them.
pub const Attributes = struct {
    vertex_position: shader.Attr(.vec3, 0),
    vertex_tex_coord: shader.Attr(.vec2, 1),
    vertex_normal: shader.Attr(.vec3, 2),
};

/// Uniforms.  Both RESERVED - engine-managed, pushed via
/// `rlSetUniformMatrix` before every draw.  Caller code that writes
/// to these via `bind(...).set` triggers a debug-build warning (see
/// `shader_interface.isReservedName`).
pub const Uniforms = struct {
    mvp: [16]f32 = @splat(0),
    mat_model: [16]f32 = @splat(0),
};

/// Outputs to fragment.  Aliases `Interp` from the common interface
/// - renaming a varying there propagates to both stages.
pub const Outputs = common.Interp;
