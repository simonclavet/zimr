//! src/shaders/pbr_vs_io.zig — typed interface for the PBR vertex
//!
//! Binding model (which @group each uniform/sampler lands in) is the
//! stage-segregated scheme documented in src/zimr.zig §3:
//! VS uniforms→group 0, samplers→group 1, FS uniforms→group 2.
//! shader.  Companion to `pbr_vs.zig`.
//!
//! Describes the vertex shader's external boundary:
//!   - Attributes: 5 vertex attributes (position, texcoord, normal,
//!     color, tangent).  Locations match raylib's
//!     `RL_DEFAULT_SHADER_ATTRIB_LOCATION_*` constants.
//!   - Uniforms: 5 mat4 transforms (model, view, projection, normal,
//!     light_space) — all engine-managed and pushed before each draw.
//!   - Outputs: 6 interpolated values (= `Interp` from
//!     `pbr_common_io`) — shared with FS for cross-stage symmetry.
//!
//! Phase 4a of `src/notes/typesafe_zig_shaders.md`.

const shader = @import("shader_interface");
const common = @import("pbr_common_io.zig");

/// Vertex attributes consumed by the PBR VS.  Locations are
/// explicit and match the host-side VAO layout in `drawing.zig`.
pub const Attributes = struct {
    vertex_position: shader.Attr(.vec3, 0),
    vertex_tex_coord: shader.Attr(.vec2, 1),
    vertex_normal: shader.Attr(.vec3, 2),
    /// vertex_color is vec4 even though glTF COLOR_0 may be vec3 —
    /// the default-VAO setup fills the missing component with 1.0.
    vertex_color: shader.Attr(.vec4, 3),
    /// glTF TANGENT is vec4: xyz is the tangent direction, w is
    /// handedness (±1).  Meshes without tangents get (1,0,0,1) from
    /// the default VAO.
    vertex_tangent: shader.Attr(.vec4, 4),
};

/// Engine-managed uniforms.  Every name is RESERVED — pushed by
/// `drawing.zig` before each draw via `rlSetUniformMatrix`.  Caller
/// code that writes to any of these via `bind(...).set` triggers a
/// debug-build warning (see `shader_interface.isReservedName`).
pub const Uniforms = struct {
    mat_model: [16]f32 = @splat(0),
    mat_view: [16]f32 = @splat(0),
    mat_projection: [16]f32 = @splat(0),
    mat_normal: [16]f32 = @splat(0),
    /// `shadow_proj * shadow_view`, set once per render() even when
    /// the FS gates shadow sampling off.
    light_space_matrix: [16]f32 = @splat(0),
};

/// Outputs to fragment.  Aliases `Interp` from the common interface
/// so VS and FS share a single source-of-truth declaration.
pub const Outputs = common.Interp;
