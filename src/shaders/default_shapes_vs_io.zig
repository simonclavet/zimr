//! src/shaders/default_shapes_vs_io.zig — typed interface for the
//!
//! Binding model (which @group each uniform/sampler lands in) is the
//! stage-segregated scheme documented in src/zimr.zig §3:
//! VS uniforms→group 0, samplers→group 1, FS uniforms→group 2.
//! default 2D shapes vertex shader.  Companion to
//! `default_shapes_vs.zig` (shader body).
//!
//! Replaces the vertex stage of the hand-written
//! the engine-emitted `default_shapes_vs.wgsl` (the wgpu engine's
//! original placeholder shader).  Goes through the typed-shader
//! pipeline → SPIR-V → spv2wgsl → `.wgsl` embedded in wasm.  See
//! `src/notes/webgpu-migration-plan.md` §3 Phase C.
//!
//! Bind-group convention matches the rest of the wgpu runtime:
//!   - `@group(0) @binding(0)` — the per-frame UBO (view-projection)
//!   - `@group(1) @binding(*)` — per-material bindings (texture +
//!     sampler; fragment stage only)
//!
//! Vertex attribute locations match the wgpu runtime's `Vertex2D`
//! layout (`src/gpu_frame.zig::ShapesBatch.Vertex2D`):
//!   - location 0: position (vec2)
//!   - location 1: uv       (vec2)
//!   - location 2: color    (vec4)

const shader = @import("shader_interface");
const common = @import("default_shapes_common_io.zig");

/// Vertex attributes consumed by this stage.  Locations match the
/// `Vertex2D` layout in `src/gpu_frame.zig` — keep them in sync if
/// either side moves.  Names use the `vertex_*` prefix; the matching
/// varying outputs use `frag_*` (in `default_shapes_common_io.zig`)
/// so codegen can emit both as module-level extern decls without
/// name collisions.
pub const Attributes = struct {
    vertex_position: shader.Attr(.vec2, 0),
    vertex_tex_coord: shader.Attr(.vec2, 1),
    vertex_color: shader.Attr(.vec4, 2),
};

/// Per-frame UBO.  Only the view-projection matrix lives here today;
/// future additions (time, viewport size for screen-space effects)
/// extend this struct.  std140 layout: a single mat4 is naturally
/// 16-byte aligned and `@sizeOf` is 64, no padding needed.
///
/// Matrix shape is `[4]@Vector(4, f32)` — the engine-wide convention
/// (`zm.Mat`, same as `examples/cube_split_vs_io.zig::Ubo.mvp`).
/// Zig 0.16 has no `@Matrix` builtin; this is the SPIR-V-compatible
/// representation that codegen knows how to bind.
pub const Ubo = struct {
    view_projection: [4]@Vector(4, f32),
};

/// Outputs to fragment — aliases `Interp` from common_io so VS
/// Outputs and FS Inputs declare the same struct exactly once.
pub const Outputs = common.Interp;
