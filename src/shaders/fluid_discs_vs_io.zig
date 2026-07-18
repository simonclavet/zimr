//! src/shaders/fluid_discs_vs_io.zig — typed interface for the instanced
//! SDF-disc vertex shader. The HARDEST shader in the engine: two read-only
//! storage buffers (`positions`, `density`) indexed by `instance_index`, plus
//! `vertex_index` for the 6-vertex quad expansion. Body in `fluid_discs_vs.zig`.

const zm = @import("zm");
const Vec2 = zm.Vec2;
const Vec = zm.Vec;
const shader = @import("shader_interface");
const common = @import("fluid_discs_common_io.zig");

/// No vertex buffer — corners come from `vertex_index`, instance data from the
/// storage buffers. The empty `Attributes` marks this as the vertex stage.
pub const Attributes = struct {};

/// VS uniform block (group 0, binding 0). Mirrors `draw3d.FluidUniforms`.
pub const Ubo = struct {
    scale: Vec2,
    offset: Vec2,
    inv_logical: Vec2,
    half_px: Vec2,
    lo: Vec,
    hi: Vec,
    density_scale: f32,
    pad0: f32,
    pad1: f32,
    pad2: f32,
};

/// Two read-only storage buffers, bound in group 0 after the Ubo:
/// `positions` at binding 1, `density` at binding 2 — matching the order the
/// compute pass writes and the host binds.
pub const Storage = struct {
    positions: shader.StorageBuf(Vec2, .read),
    density: shader.StorageBuf(Vec2, .read),
};

/// Builtins the body reads.
pub const Builtins = struct {
    vertex_index: shader.Builtin(.vertex_index),
    instance_index: shader.Builtin(.instance_index),
};

/// Varyings to the FS — colour + quad corner.
pub const Outputs = common.Interp;
