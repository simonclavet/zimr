//! src/shaders/default_shapes_fs_io.zig — typed interface for the
//!
//! Binding model (which @group each uniform/sampler lands in) is the
//! stage-segregated scheme documented in src/zimr.zig §3:
//! VS uniforms→group 0, samplers→group 1, FS uniforms→group 2.
//! default 2D shapes fragment shader.  Companion to
//! `default_shapes_fs.zig` (shader body).
//!
//! Replaces the fragment stage of the hand-written
//! the engine-emitted `default_shapes_fs.wgsl`.  See
//! `src/notes/webgpu-migration-plan.md` §3 Phase C for context.
//!
//! Output is the per-fragment color (texture sample × per-vertex tint).
//! Untextured drawing binds the 1×1 white texture so the sample is
//! identity and the per-vertex color flows through unchanged — single
//! shader handles both code paths.

const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");
const common = @import("default_shapes_common_io.zig");

/// Varying inputs from the vertex stage.  Field names + order MUST
/// match `default_shapes_vs_io.Outputs` (both alias `common.Interp`),
/// so renames in the common file propagate to both stages.
pub const Inputs = common.Interp;

/// Texture samplers.  Single sampler bound to slot 1 (.albedo).
/// Engine `loadShader` walks this struct at load time and binds the
/// texture+sampler to its declared slot via the material bind group.
///
/// The sampler slot/binding numbering: WebGL uses sequential ints
/// (0, 1, 2…); WebGPU uses an explicit `@group(N) @binding(N)` pair.
/// `Sampler2D(.albedo, .{})` maps to the engine's per-material bind group
/// — see `src/renderer_2d.zig::buildMaterialBindGroup` for the wgpu
/// side and the equivalent in `rlgl.zig` for the GL side.
pub const Samplers = struct {
    texture0: shader.Sampler2D(.albedo, .{}),
};

/// Stage output: the final fragment color.  RGBA, sRGB pre-multiplied
/// or not depending on the swapchain configuration; the engine doesn't
/// gamma-correct here.
pub const Outputs = struct {
    out_color: Vec,
};
