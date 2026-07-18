//! src/shaders/default_shapes_common_io.zig — interpolated
//!
//! Binding model (which @group each uniform/sampler lands in) is the
//! stage-segregated scheme documented in src/zimr.zig §3:
//! VS uniforms→group 0, samplers→group 1, FS uniforms→group 2.
//! varyings shared between `default_shapes_vs.zig` and
//! `default_shapes_fs.zig`.  Same "single source of truth" pattern
//! as `unlit_common_io.zig`.
//!
//! The default_shapes pair is the wgpu engine's bedrock 2D shader:
//! drives every `drawRectangle`, `drawCircle`, `drawTexturedQuad`,
//! `drawText` call.  Untextured draws bind the 1×1 white texture
//! (see `src/wgpu_texture.zig::createWhite1x1`) so the sampled
//! albedo is identity and the per-vertex color flows through
//! unchanged — single shader handles both cases.  See
//! `src/notes/webgpu-migration-plan.md` §3 Phase C for context.
//!
//! Field names match the legacy hand-written WGSL in
//! the engine-emitted WGSL so the wgpu runtime's bind-group
//! conventions don't have to change when this shader replaces the
//! hand-written one.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;

/// Varyings from vertex to fragment.  The vertex stage declares
/// these as its `Outputs`; the fragment stage declares the same
/// struct as its `Inputs`.  Renaming a field here propagates to
/// both stages — and any caller that reads them via the typed
/// extern accessor — by construction.
///
/// Naming convention: `frag_*` for varyings (interpolated, read by
/// FS); the matching vertex attributes use `vertex_*` (declared in
/// `default_shapes_vs_io.zig`).  This keeps Attributes and Outputs
/// in non-colliding namespaces — codegen emits both as module-level
/// extern decls, and a duplicate name across the two would fail
/// compilation.
pub const Interp = struct {
    /// Per-vertex UV, interpolated across the triangle.  For
    /// untextured draws (bound 1×1 white texture) this is still
    /// emitted to keep the same vertex layout; the sample just
    /// returns white.
    frag_tex_coord: Vec2,
    /// Per-vertex tint, interpolated.  Multiplied with the texture
    /// sample to produce the final fragment color.  For untextured
    /// draws this is the entire visible color.
    frag_color: Vec,
};
