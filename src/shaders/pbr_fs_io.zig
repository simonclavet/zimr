//! src/shaders/pbr_fs_io.zig — typed interface for the PBR
//!
//! Binding model (which @group each uniform/sampler lands in) is the
//! stage-segregated scheme documented in src/zimr.zig §3:
//! VS uniforms→group 0, samplers→group 1, FS uniforms→group 2.
//! fragment shader.  Companion to `pbr_fs.zig`.
//!
//! Describes the fragment shader's external boundary:
//!   - Inputs: 6 interpolated values from VS (= `common.Interp`).
//!   - Samplers: 6 texture bindings — base color, metallic-roughness,
//!     normal, occlusion, emissive, shadow map.
//!   - Uniforms: PBR factors (col_diffuse, metallic, roughness,
//!     emissive, view_pos, ambient), directional + point light
//!     arrays sized by `common.MAX_*_LIGHTS`, fog params, shadow
//!     gate flag.
//!   - Outputs: `out_color` (vec4 — RGB color + alpha).
//!
//! Sampler slot bindings here drive the schema-driven sampler
//! auto-binding in `shader_runtime.loadShader` (Phase 1).  Once
//! Phase 4b lands the damaged_helmet migration, `drawMesh`'s
//! texture-binding loop will look up slot indices from this struct
//! rather than the hardcoded `SHADER_LOC_MAP_*` table — and the
//! friendly-name fallback in `loadShaderFromMemory` becomes deletable.
//!
//! Phase 4a of `src/notes/typesafe_zig_shaders.md`.

const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");
const common = @import("pbr_common_io.zig");

/// Interpolated inputs from `pbr_vs`.  Field order MUST match
/// `pbr_vs_io.Outputs` (= `common.Interp` for both stages →
/// trivially enforced).
pub const Inputs = common.Interp;

/// Texture samplers.  The `kind` of each `Sampler2D(.kind, .{})` drives
/// `loadShader`'s auto-binding to the matching material-map slot.
/// glTF metallic-roughness workflow needs all of these except the
/// shadow map, which is engine-managed.
pub const Samplers = struct {
    /// Base color (albedo).  Naming follows the legacy raylib
    /// `texture0` convention — strips to `uniform sampler2D texture0`
    /// in the cross-compiled GLSL.
    texture0: shader.Sampler2D(.albedo, .{}),
    metallic_roughness: shader.Sampler2D(.metalness, .{}),
    normal: shader.Sampler2D(.normal, .{}),
    occlusion: shader.Sampler2D(.occlusion, .{}),
    emissive: shader.Sampler2D(.emission, .{}),
    /// Depth-in-red shadow map.  Bound at a fixed slot (`.cubemap`
    /// — chosen because it's an unused enum value in the glTF
    /// metallic-roughness pipeline, not because it's a cubemap) so
    /// that the shadow-pass setup in `render.zig` can pre-bind the
    /// shadow texture without colliding with material slots.
    shadow_map: shader.Sampler2D(.cubemap, .{}),
};

/// Per-stage uniform block: a SINGLE WebGPU uniform-buffer binding at
/// @group(2) @binding(0) (replaces the old loose-uniform scheme that
/// emitted one binding per field and blew past the 12-uniform-buffers-
/// per-stage device limit).  std140 layout: stored vec3s are widened to
/// vec4 (read `.xyz` in the shader) so every non-scalar field is exactly
/// 16 bytes or a 16-byte multiple, and the scalar tail is a whole number
/// of 16-byte rows -- @sizeOf == 368, divisible by 16, NO interior pad.
/// The host mirror MUST match this byte-for-byte.
///
/// Most fields are RESERVED -- pushed by the engine each draw.
pub const Ubo = struct {
    // ---- vec4 fields (16-byte aligned, 16 bytes each) ----
    /// Material tint, multiplied with base-color sample.  Reserved.
    col_diffuse: Vec = .{ 1, 1, 1, 1 },
    /// World-space camera position (xyz; w unused).  Used to compute the
    /// view vector for specular reflectance.  Reserved.
    view_pos: Vec = .{ 0, 0, 0, 0 },
    /// Constant ambient term added before tone-map (xyz; w unused).
    /// Reserved.
    ambient_color: Vec = .{ 0, 0, 0, 0 },
    /// glTF emissiveFactor (xyz; w unused).  Multiplied with the emissive
    /// sample.  Default zero so non-emissive materials stay dark.
    /// Reserved.
    emissive_factor: Vec = .{ 0, 0, 0, 0 },
    /// Fog tint (xyz; w unused).  Reserved.
    fog_color: Vec = .{ 0, 0, 0, 0 },

    // ---- light arrays.  Element type is vec4: WebGPU's std140 uniform
    //      layout requires array element stride to be a multiple of 16,
    //      so a [N]vec3 (stride 12) or [N]f32 (stride 4) is rejected.
    //      The host packs accordingly (.xyz / .x used; rest ignored). ----
    directional_light_dir: [common.max_directional_lights]Vec =
        @splat(.{ 0, 0, 0, 0 }),
    directional_light_color: [common.max_directional_lights]Vec =
        @splat(.{ 0, 0, 0, 0 }),
    point_light_pos: [common.max_point_lights]Vec =
        @splat(.{ 0, 0, 0, 0 }),
    point_light_color: [common.max_point_lights]Vec =
        @splat(.{ 0, 0, 0, 0 }),
    /// Per-point-light fall-off range in world units (.x used; padded to
    /// vec4 for the std140 array stride).  Reserved.
    point_light_range: [common.max_point_lights]Vec =
        @splat(.{ 0, 0, 0, 0 }),

    // ---- scalar tail (4-byte packed; exactly two 16-byte rows, so the
    //      struct ends on a 16-byte boundary with no trailing pad) ----
    /// glTF metallicFactor (0=dielectric, 1=metal).  Reserved.
    metallic_factor: f32 = 1,
    /// glTF roughnessFactor (0=mirror, 1=fully rough).  Reserved.
    roughness_factor: f32 = 1,
    /// Number of active directional lights (at most max_directional_lights).
    /// Reserved.
    directional_light_count: i32 = 0,
    /// Number of active point lights (at most max_point_lights).  Reserved.
    point_light_count: i32 = 0,
    /// Boolean flag (0 / 1) -- engine sets based on scene settings.
    fog_enabled: i32 = 0,
    fog_near: f32 = 0,
    fog_far: f32 = 0,
    /// Boolean flag (0 / 1) gating shadow-map sampling.  When 0 the FS
    /// skips `computeShadow` and uses 1.0 unconditionally.
    shadow_enabled: i32 = 0,
};

/// Stage output.  Single attachment — the rendered color buffer.
pub const Outputs = struct {
    out_color: Vec,
};
