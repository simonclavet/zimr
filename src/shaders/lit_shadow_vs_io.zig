//! src/shaders/lit_shadow_vs_io.zig — typed interface for the
//! shadow-mapped Lambert vertex shader. Companion to `lit_shadow_vs.zig`.
//!
//! Binding model (which @group each uniform/sampler lands in) is the
//! stage-segregated scheme documented in src/zimr.zig §3:
//! VS uniforms→group 0, samplers→group 1, FS uniforms→group 2.
//!
//! Geometry is pre-placed in world space (no per-object model matrix),
//! so `mvp` is the camera view-projection and `light_vp` is the light's
//! view-projection; the world-space vertex position feeds both. Both
//! matrices live in ONE combined group-0 `Ubo` (single binding) — the
//! same shape the depth shader uses.

const shader = @import("shader_interface");
const common = @import("lit_shadow_common_io.zig");

/// Vertex attributes. position=0, normal=1 (this example bakes only
/// position + normal into its interleaved buffer — no texcoord).
pub const Attributes = struct {
    vertex_position: shader.Attr(.vec3, 0),
    vertex_normal: shader.Attr(.vec3, 1),
};

/// VS uniform block (group 0, one binding). `mvp` = camera view-
/// projection ⊗ model. `light_vp` = light view-projection ⊗ model (→ the
/// fragment's light-clip position). `normal_matrix` transforms the object
/// normal into world space (the model's rotation; translation/uniform
/// scale drop out on normalize) so animated objects shade correctly.
pub const Ubo = struct {
    mvp: [4]@Vector(4, f32),
    light_vp: [4]@Vector(4, f32),
    normal_matrix: [4]@Vector(4, f32),
};

/// Outputs to fragment. Aliases `Interp` from the common interface.
pub const Outputs = common.Interp;
